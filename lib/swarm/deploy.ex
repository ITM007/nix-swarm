defmodule Swarm.Deploy do
  @moduledoc false

  @default_source "."
  @default_remote_path "/etc/nixos/nix-swarm"
  @default_nixos_dir "/etc/nixos"
  @tar_excludes [".git", ".serena", "result", "_build", "deps"]
  @machine_glob "machines/*.nix"

  def defaults(source \\ @default_source) do
    resolved_source = Path.expand(source)

    %{
      source: resolved_source,
      host_source: @machine_glob,
      hosts: default_hosts(resolved_source),
      remote_path: @default_remote_path,
      nixos_dir: @default_nixos_dir,
      validate_before_apply: true,
      preview_before_apply: true,
      apply_on_success: true
    }
  end

  def run(opts) do
    plan = plan(opts) |> validate!()

    if plan.dry_run do
      plan
    else
      results =
        Enum.map(plan.results, fn result ->
          sync!(result.sync_command)
          rebuild_output = rebuild!(result.rebuild_command)
          Map.put(result, :rebuild_output, rebuild_output)
        end)

      %{plan | results: results}
    end
  end

  def plan(opts) do
    source = Path.expand(Keyword.get(opts, :source, @default_source))
    remote_path = Keyword.get(opts, :remote_path, @default_remote_path)
    nixos_dir = Keyword.get(opts, :nixos_dir, @default_nixos_dir)
    hosts = hosts(opts, source)
    dry_run = Keyword.get(opts, :dry_run, false)

    validate_inputs!(source, hosts)

    machine_files = machine_files(source)
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

  def hosts(opts), do: hosts(opts, Path.expand(Keyword.get(opts, :source, @default_source)))

  def hosts(opts, source) do
    case {Keyword.get(opts, :hosts), Keyword.get(opts, :host)} do
      {nil, nil} ->
        default_hosts(source)

      {nil, host} ->
        parse_hosts(host)

      {hosts, _host} ->
        parse_hosts(hosts)
    end
  end

  def default_hosts(source \\ @default_source) do
    source
    |> Path.expand()
    |> machine_files()
    |> Enum.map(&machine_host/1)
  end

  def machine_files(source) do
    source
    |> Path.join(@machine_glob)
    |> Path.wildcard()
    |> Enum.sort()
  end

  def validation_commands(machine_files) do
    Enum.map(machine_files, &validation_command/1)
  end

  def rebuild_command(opts) do
    ["nixos-rebuild", "switch"]
    |> maybe_append_option("--flake", Keyword.get(opts, :flake))
    |> maybe_append_option("--build-host", Keyword.get(opts, :build_host))
    |> Enum.map_join(" ", &shell_escape/1)
  end

  def sync_command(source, host, remote_path) do
    tar_args =
      @tar_excludes
      |> Enum.map_join(" ", &shell_escape("--exclude=" <> &1))

    remote_extract =
      """
      set -euo pipefail
      remote_path=#{shell_escape(remote_path)}
      staging="${remote_path}.new"
      backup="${remote_path}.backup-$(date +%Y%m%d%H%M%S)"
      rm -rf "$staging"
      mkdir -p "$staging"
      tar -xzf - -C "$staging"
      if [ -e "$remote_path" ]; then
        cp -a "$remote_path" "$backup"
      fi
      rm -rf "$remote_path"
      mv "$staging" "$remote_path"
      if [ -e "$remote_path/secrets/swarm.cookie" ]; then
        if [ "$(id -u)" = "0" ]; then
          chown root:root "$remote_path/secrets/swarm.cookie"
          chmod 600 "$remote_path/secrets/swarm.cookie"
        elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
          sudo chown root:root "$remote_path/secrets/swarm.cookie"
          sudo chmod 600 "$remote_path/secrets/swarm.cookie"
        else
          chmod 600 "$remote_path/secrets/swarm.cookie"
        fi
      fi
      """
      |> String.trim()

    """
    cd #{shell_escape(source)} && tar #{tar_args} -czf - . | ssh -- #{shell_escape(host)} #{shell_escape(remote_extract)}
    """
    |> String.trim()
  end

  def rebuild_host_command(host, nixos_dir, opts) do
    remote_cmd =
      """
      set -euo pipefail
      cd #{shell_escape(nixos_dir)}
      #{rebuild_command(opts)}
      """
      |> String.trim()

    "ssh -- #{shell_escape(host)} #{shell_escape(remote_cmd)}"
  end

  defp validate!(plan) do
    Enum.each(plan.validation.commands, &run_shell!/1)
    plan
  end

  defp parse_hosts(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp validation_command(machine_file) do
    expr =
      """
      let eval = import <nixpkgs/nixos/lib/eval-config.nix> {
        system = builtins.currentSystem;
        modules = [ (builtins.toPath #{nix_string_literal(machine_file)}) ];
        specialArgs = { inputs = {}; };
      }; in {
        node = eval.config.services.swarm.nodeName;
        peers = eval.config.services.swarm.peers;
        services = builtins.attrNames eval.config.services.swarm.services;
        ingress = builtins.attrNames eval.config.services.swarm.ingress.sites;
      }
      """
      |> String.trim()

    "nix-instantiate --eval --strict --expr #{shell_escape(expr)}"
  end

  defp sync!(command) do
    run_shell!(command)
  end

  defp rebuild!(command) do
    run_shell!(command)
  end

  defp run_shell!(command) do
    case System.cmd("sh", ["-lc", command], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "command failed with status #{status}: #{output}"
    end
  end

  defp maybe_append_option(args, _flag, nil), do: args
  defp maybe_append_option(args, flag, value), do: args ++ [flag, value]

  defp validate_inputs!(source, hosts) do
    if hosts == [] do
      raise ArgumentError, "at least one host is required"
    end

    if not File.dir?(source) do
      raise ArgumentError, "source directory does not exist: #{source}"
    end

    if not File.exists?(Path.join(source, "cluster/cluster.nix")) do
      raise ArgumentError,
            "cluster file does not exist: #{Path.join(source, "cluster/cluster.nix")}"
    end

    if machine_files(source) == [] do
      raise ArgumentError, "no machine files found under #{Path.join(source, "machines")}"
    end
  end

  defp machine_host(machine_file) do
    machine_file
    |> Path.basename()
    |> Path.rootname()
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp nix_string_literal(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("${", "\\${")

    "\"#{escaped}\""
  end
end
