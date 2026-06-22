defmodule NixSwarm.Deploy do
  @moduledoc false

  alias NixSwarm.Paths

  @default_remote_path "/etc/nixos/nix-swarm"
  @default_nixos_dir "/etc/nixos"
  @tar_excludes [".git", ".serena", "result", "_build", "deps"]
  def defaults(source \\ nil) do
    resolved_source = source_root(source)
    machines_dir = default_machines_dir(resolved_source)
    cluster_file = default_cluster_file(resolved_source)

    %{
      source: resolved_source,
      cluster_file: cluster_file,
      machines_dir: machines_dir,
      host_source: Path.relative_to(machines_dir, resolved_source) <> "/*.nix",
      hosts: default_hosts(resolved_source, machines_dir),
      remote_path: @default_remote_path,
      nixos_dir: @default_nixos_dir,
      validate_before_apply: true,
      preview_before_apply: true,
      apply_on_success: true
    }
  end

  def run(opts) do
    opts = normalize_opts(opts)
    plan = plan(opts) |> validate!()

    if plan.dry_run do
      plan
    else
      results =
        Enum.map(plan.results, fn result ->
          sync!(result.host, result.sync_command)
          rebuild_output = rebuild!(result.host, result.rebuild_command)
          Map.put(result, :rebuild_output, rebuild_output)
        end)

      %{plan | results: results}
    end
  end

  def plan(opts) do
    opts = normalize_opts(opts)
    source = source_root(Keyword.get(opts, :source))

    cluster_file =
      Path.expand(Keyword.get(opts, :cluster_file, default_cluster_file(source)))

    machines_dir = Path.expand(Keyword.get(opts, :machines_dir, default_machines_dir(source)))
    remote_path = Keyword.get(opts, :remote_path, @default_remote_path)
    nixos_dir = Keyword.get(opts, :nixos_dir, @default_nixos_dir)
    hosts = hosts(opts, source, machines_dir)
    dry_run = Keyword.get(opts, :dry_run, false)

    validate_inputs!(source, hosts, cluster_file, machines_dir)

    machine_files = machine_files_from_dir(machines_dir)
    validation_commands = validation_commands(machine_files)

    results =
      Enum.map(hosts, fn host ->
        %{
          host: host,
          sync_command: sync_command(source, host, remote_path),
          rebuild_command: rebuild_host_command(host, nixos_dir, opts)
        }
      end)

    %{
      dry_run: dry_run,
      source: source,
      cluster_file: cluster_file,
      machines_dir: machines_dir,
      remote_path: remote_path,
      nixos_dir: nixos_dir,
      hosts: hosts,
      validation: %{
        machine_files: machine_files,
        commands: validation_commands
      },
      results: results
    }
  end

  def hosts(opts, source, machines_dir \\ nil) do
    opts = normalize_opts(opts)
    machines_dir = if is_nil(machines_dir), do: default_machines_dir(source), else: machines_dir

    case {Keyword.get(opts, :hosts), Keyword.get(opts, :host)} do
      {nil, nil} ->
        default_hosts(source, machines_dir)

      {nil, host} ->
        parse_hosts(host)

      {hosts, _host} ->
        parse_hosts(hosts)
    end
  end

  def default_hosts(source \\ nil, machines_dir \\ nil) do
    source = source_root(source)

    machines_dir =
      if is_nil(machines_dir), do: default_machines_dir(source), else: Path.expand(machines_dir)

    machines_dir
    |> machine_files_from_dir()
    |> Enum.map(&machine_host/1)
  end

  def machine_files(source) do
    source
    |> source_root()
    |> default_machines_dir()
    |> machine_files_from_dir()
  end

  defp source_root(nil), do: Paths.default_source()
  defp source_root(source), do: Path.expand(source)

  defp default_cluster_file(source) do
    source = Path.expand(source)
    # Flat layout: cluster.nix at root, otherwise cluster/cluster.nix (legacy)
    flat = Path.join(source, "cluster.nix")
    nested = Path.join(source, "cluster/cluster.nix")
    examples = Path.join(source, "examples/config/cluster/cluster.nix")

    cond do
      File.exists?(flat) -> flat
      File.exists?(nested) -> nested
      true -> examples
    end
  end

  defp default_machines_dir(source) do
    source = Path.expand(source)
    flat = Path.join(source, "machines.nix")
    nested = Path.join(source, "machines")
    examples = Path.join(source, "examples/config/machines")

    cond do
      File.exists?(flat) -> Path.dirname(flat)
      machine_files_from_dir(nested) != [] -> nested
      true -> examples
    end
  end

  def machine_files_from_dir(machines_dir) do
    machines_dir
    |> Path.expand()
    |> Path.join("*.nix")
    |> Path.wildcard()
    |> Enum.sort()
  end

  def validation_commands(machine_files) do
    Enum.map(machine_files, &validation_command/1)
  end

  def rebuild_command(opts, nixos_dir \\ @default_nixos_dir) do
    nixos_config = Path.join(nixos_dir, "configuration.nix")

    ["nixos-rebuild", "switch"]
    |> maybe_append_option("--flake", Keyword.get(opts, :flake))
    |> maybe_append_option(
      "-I",
      if(Keyword.has_key?(opts, :flake), do: nil, else: "nixos-config=#{nixos_config}")
    )
    |> maybe_append_option("--build-host", Keyword.get(opts, :build_host))
    |> Enum.map_join(" ", &shell_escape/1)
  end

  def sync_command(source, host, remote_path) do
    validate_ssh_host!(host)
    validate_source_path!(source, "source path")
    remote_path = validate_remote_path!(remote_path, "remote path")

    tar_args =
      @tar_excludes
      |> Enum.map_join(" ", &shell_escape("--exclude=" <> &1))

    remote_extract =
      """
      set -euo pipefail
      #{remote_root_prelude("remote deployment requires root or passwordless sudo to manage #{remote_path}")}
      remote_path=#{shell_escape(remote_path)}
      staging="${remote_path}.new"
      backup="${remote_path}.backup-$(date +%Y%m%d%H%M%S)"
      as_root rm -rf "$staging"
      as_root mkdir -p -m 700 "$staging"
      as_root tar -xzf - -C "$staging"
      if as_root test -e "$remote_path"; then
        as_root cp -a "$remote_path" "$backup"
      fi
      as_root rm -rf "$remote_path"
      as_root mv "$staging" "$remote_path"
      if as_root test -d "$backup/secrets"; then
        as_root mkdir -p -m 700 "$remote_path/secrets"
        as_root chmod 700 "$remote_path/secrets"
        as_root cp -an "$backup/secrets/." "$remote_path/secrets/" 2>/dev/null || as_root cp -a "$backup/secrets/." "$remote_path/secrets/"
      fi
      if as_root test -d "$remote_path/secrets"; then
        as_root chown root:root "$remote_path/secrets"
        as_root chmod 711 "$remote_path/secrets"
      fi
      if as_root test -e "$remote_path/secrets/nix-swarm.cookie"; then
        as_root chown root:root "$remote_path/secrets/nix-swarm.cookie"
        as_root chmod 600 "$remote_path/secrets/nix-swarm.cookie"
      fi
      """
      |> String.trim()

    """
    cd #{shell_escape(source)} && tar #{tar_args} -czf - . | #{ssh_command(host, remote_extract)}
    """
    |> String.trim()
  end

  def rebuild_host_command(host, nixos_dir, opts) do
    validate_ssh_host!(host)
    nixos_dir = validate_remote_path!(nixos_dir, "NixOS directory")

    remote_cmd =
      """
      set -euo pipefail
      #{remote_root_prelude("remote rebuild requires root or passwordless sudo")}
      cd #{shell_escape(nixos_dir)}
      as_root #{rebuild_command(opts, nixos_dir)}
      """
      |> String.trim()

    ssh_command(host, remote_cmd)
  end

  defp remote_root_prelude(message) do
    """
    if [ "$(id -u)" = "0" ]; then
      as_root() { "$@"; }
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
      as_root() { sudo "$@"; }
    else
      echo #{shell_escape(message)} >&2
      exit 1
    fi
    """
    |> String.trim()
  end

  defp validate!(plan) do
    plan.validation.commands
    |> Enum.zip(plan.validation.machine_files)
    |> Enum.each(fn {command, machine_file} ->
      run_shell!(command, "validation for #{machine_file}")
    end)

    plan
  end

  defp parse_hosts(value) do
    value
    |> List.wrap()
    |> case do
      [single] when is_binary(single) ->
        single
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      values ->
        values
        |> Enum.map(&(&1 |> to_string() |> String.trim()))
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp validation_command(machine_file) do
    expr =
      """
      let eval = import <nixpkgs/nixos/lib/eval-config.nix> {
        system = builtins.currentSystem;
        modules = [ (builtins.toPath #{NixSwarm.nix_string_literal(machine_file)}) ];
        specialArgs = { inputs = {}; };
      }; in {
        node = eval.config.services.nix-swarm.nodeName;
        peers = eval.config.services.nix-swarm.peers;
        services = builtins.attrNames eval.config.services.nix-swarm.services;
        ingress = builtins.attrNames eval.config.services.nix-swarm.ingress.sites;
      }
      """
      |> String.trim()

    "nix-instantiate --eval --strict --expr #{shell_escape(expr)}"
  end

  defp sync!(host, command) do
    run_shell!(command, "sync to #{host}")
  end

  defp rebuild!(host, command) do
    run_shell!(command, "rebuild on #{host}")
  end

  defp run_shell!(command, context) do
    case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "#{context} failed with status #{status}: #{String.trim(output)}"
    end
  end

  defp maybe_append_option(args, _flag, nil), do: args
  defp maybe_append_option(args, flag, value), do: args ++ [flag, value]

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Enum.to_list(opts)

  defp validate_inputs!(source, hosts, cluster_file, machines_dir) do
    if hosts == [] do
      raise ArgumentError, "at least one host is required"
    end

    if not File.dir?(source) do
      raise ArgumentError, "source directory does not exist: #{source}"
    end

    if not File.exists?(cluster_file) do
      raise ArgumentError, "cluster file does not exist: #{cluster_file}"
    end

    if machine_files_from_dir(machines_dir) == [] do
      raise ArgumentError, "no machine files found under #{machines_dir}"
    end
  end

  defp validate_ssh_host!(host) do
    host = to_string(host)

    cond do
      String.trim(host) == "" ->
        raise ArgumentError, "SSH host cannot be blank"

      String.match?(host, ~r/[\x00-\x20]/) ->
        raise ArgumentError, "SSH host contains unsupported whitespace or control characters"

      true ->
        host
    end
  end

  defp validate_remote_path!(path, label) do
    path = to_string(path)
    parts = Path.split(path)

    cond do
      Path.type(path) != :absolute ->
        raise ArgumentError, "#{label} must be an absolute path: #{path}"

      ".." in parts ->
        raise ArgumentError, "#{label} must not contain '..': #{path}"

      true ->
        path
    end
  end

  defp validate_source_path!(path, label) do
    path = to_string(path)

    cond do
      String.trim(path) == "" ->
        raise ArgumentError, "#{label} cannot be blank"

      String.match?(path, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/) ->
        raise ArgumentError, "#{label} contains unsupported control characters"

      String.contains?(path, "`") or String.contains?(path, "$(") or
          String.contains?(path, "${") ->
        raise ArgumentError, "#{label} contains shell metacharacters"

      true ->
        path
    end
  end

  defp ssh_command(host, remote_command) do
    [
      "ssh",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=10",
      "-o",
      "ServerAliveInterval=10",
      "-o",
      "ServerAliveCountMax=3",
      "-o",
      "StrictHostKeyChecking=accept-new",
      "--",
      host,
      remote_command
    ]
    |> Enum.map_join(" ", &shell_escape/1)
  end

  defp machine_host(machine_file) do
    machine_file
    |> Path.basename()
    |> Path.rootname()
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
