defmodule NixSwarm.CLI do
  @moduledoc false

  alias NixSwarm.ConfigFiles

  @strict_opts [
    help: :boolean,
    version: :boolean,
    target: :string,
    cookie: :string,
    cookie_file: :string,
    name: :string,
    template: :string,
    force: :boolean,
    lines: :integer,
    refresh_ms: :integer,
    source: :string,
    cluster_file: :string,
    machines_dir: :string,
    services_dir: :string,
    remote_path: :string,
    nixos_dir: :string
  ]

  def main(argv) do
    case run(argv) do
      :ok ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, "error: #{message}")
        System.halt(1)
    end
  end

  def run(argv, tui_runner \\ &NixSwarm.TUI.run/1) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @strict_opts)
    validate_parse_result!(opts, invalid)
    opts = apply_launch_defaults(opts)
    maybe_warn_cookie(opts)

    cond do
      Keyword.get(opts, :version, false) ->
        IO.puts(NixSwarm.release_label())
        :ok

      Keyword.get(opts, :help, false) ->
        print_help()
        :ok

      args == ["cluster", "ensure"] ->
        IO.puts("Ensuring cluster nodes are running nix-swarmd...\n")

        result =
          NixSwarm.Cluster.Ensure.run(
            Keyword.take(opts, [:source, :cluster_file, :cookie, :force])
          )

        Enum.each(result.nodes, fn node ->
          case node.status do
            :ok ->
              IO.puts("  #{node.node}: #{node.action} (#{node.message || "ok"})")

            :error ->
              IO.puts("  #{node.node}: ERROR - #{node.message}")
              IO.puts(:stderr, "error: #{node.node}: #{node.message}")
          end
        end)

        if result.ok, do: :ok, else: {:error, "some nodes failed; see above"}

      args == ["cluster", "init"] ->
        IO.puts("Initializing nix-swarm cluster...\n")
        IO.puts("This will bootstrap all machines defined in cluster.nix.\n")

        result =
          NixSwarm.Cluster.Ensure.run(
            Keyword.take(opts, [:source, :cluster_file, :cookie, :force])
          )

        Enum.each(result.nodes, fn node ->
          IO.puts("  #{node.node}: #{node.action} (#{node.message || "ok"})")
        end)

        IO.puts("\nTip: ensure ports 4369 and 4370 are open on this machine's firewall")

        IO.puts("  On NixOS: add 4369 and 4370 to networking.firewall.allowedTCPPorts")

        IO.puts("  On other: ufw allow 4369/tcp && ufw allow 4370/tcp")

      args == ["service", "create"] ->
        name = Keyword.fetch!(opts, :name)
        template = Keyword.get(opts, :template, "web")
        paths = NixSwarm.ConfigFiles.defaults()
        services_dir = paths.services_dir

        case NixSwarm.Service.Templates.generate(template, name) do
          {:ok, tpl} ->
            output = Path.join(services_dir, tpl.filename)
            File.mkdir_p!(services_dir)
            File.write!(output, tpl.content)
            IO.puts("Created #{output}")
            IO.puts("Service: #{name}")
            IO.puts("Template: #{template} — #{tpl.description}")
            IO.puts("Next: add the service to your cluster.nix file")
            :ok

          {:error, msg} ->
            IO.puts(:stderr, msg)
            {:error, msg}
        end

      args == ["service", "list"] ->
        IO.puts("Available service templates:\n#{NixSwarm.Service.Templates.list()}")
        :ok

      args in [[], ["tui"], ["help"]] ->
        if args == ["help"] do
          print_help()
          :ok
        else
          tui_runner.(opts)
        end

      true ->
        {:error, legacy_command_error(args)}
    end
  rescue
    error in [NixSwarm.Remote.Error, ArgumentError, RuntimeError] ->
      {:error, Exception.message(error)}
  end

  defp validate_parse_result!(_opts, [{option, nil} | _invalid]) do
    raise ArgumentError, "unsupported option: #{option}"
  end

  defp validate_parse_result!(_opts, [{option, value} | _invalid]) do
    raise ArgumentError, "invalid value for #{option}: #{value}"
  end

  defp validate_parse_result!(opts, []) do
    validate_positive_integer!(opts, :lines, "--lines")
    validate_minimum_integer!(opts, :refresh_ms, "--refresh-ms", 100)
  end

  defp validate_positive_integer!(opts, key, label) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      _value -> raise ArgumentError, "#{label} must be a positive integer"
    end
  end

  defp validate_minimum_integer!(opts, key, label, minimum) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value >= minimum -> :ok
      _value -> raise ArgumentError, "#{label} must be at least #{minimum}"
    end
  end

  defp maybe_warn_cookie(opts) do
    if Keyword.has_key?(opts, :cookie) do
      IO.puts(
        :stderr,
        "warning: passing --cookie on the command line exposes the cookie via `ps`/process listings; " <>
          "prefer --cookie-file, NIX_SWARM_COOKIE_FILE, or NIX_SWARM_COOKIE environment variables"
      )
    end
  end

  defp apply_launch_defaults(opts) do
    config_paths = config_paths(opts)
    maybe_set_default_cookie_env(opts, config_paths)
    maybe_put_default_target(opts, config_paths)
  end

  defp config_paths(opts) do
    defaults = ConfigFiles.defaults(Keyword.get(opts, :source))

    ConfigFiles.normalize_paths(%{
      source: defaults.source,
      cluster_file: Keyword.get(opts, :cluster_file, defaults.cluster_file),
      machines_dir: Keyword.get(opts, :machines_dir, defaults.machines_dir),
      services_dir: Keyword.get(opts, :services_dir, defaults.services_dir)
    })
  end

  defp maybe_set_default_cookie_env(opts, config_paths) do
    cond do
      Keyword.has_key?(opts, :cookie) ->
        :ok

      Keyword.has_key?(opts, :cookie_file) ->
        :ok

      present_env(System.get_env("NIX_SWARM_COOKIE")) ->
        :ok

      present_env(System.get_env("NIX_SWARM_COOKIE_FILE")) ->
        :ok

      cookie_path = ConfigFiles.local_cookie_file(config_paths) ->
        System.put_env("NIX_SWARM_COOKIE_FILE", cookie_path)

      true ->
        :ok
    end
  end

  defp maybe_put_default_target(opts, config_paths) do
    cond do
      Keyword.has_key?(opts, :target) ->
        opts

      env_target = present_env(System.get_env("NIX_SWARM_TARGET")) ->
        Keyword.put(opts, :target, env_target)

      config_target = ConfigFiles.default_target(config_paths) ->
        Keyword.put(opts, :target, config_target)

      true ->
        opts
    end
  end

  defp present_env(nil), do: nil
  defp present_env(""), do: nil
  defp present_env(value), do: value

  defp legacy_command_error(args) do
    command = Enum.join(args, " ")
    launch = NixSwarm.operator_command()
    explicit_launch = NixSwarm.operator_launch()

    """
    `#{command}` was removed from the public command surface.

      Nix-Swarm is TUI-first in #{NixSwarm.release_label()} alpha. Launch the console instead:
      #{launch}
      #{explicit_launch}

    Inside the TUI you can:
      - inspect dashboard, map, machines, and services
      - restart services and reconcile the cluster
      - dry-run or apply config changes
      - add, edit, and delete machine/service files
      - roll out updates to running nodes
    """
    |> String.trim()
  end

  defp print_help do
    launch = NixSwarm.operator_launch()

    IO.puts("""
    Nix-Swarm

    Launch the operator TUI:
      #{NixSwarm.operator_command()}
      #{launch}
      #{launch} --source /path/to/checkout

    Bootstrap cluster nodes from cluster.nix:
      nix-swarm cluster ensure

    Remote target:
      --target NODE              remote Nix-Swarm node to connect to
                                 defaults to NIX_SWARM_TARGET or the first peer in cluster/cluster.nix

    Remote connection options:
      --cookie VALUE             explicit Erlang cookie (discouraged; visible in `ps`)
      --cookie-file PATH         read the cookie from a file
      --name NAME@HOST           override the local control node name when longnames need a reachable LAN address

    TUI options:
      --lines N                  default log line count (default: 50)
      --refresh-ms N             auto-refresh interval in milliseconds (default: 30000)
      --source PATH              local Nix-Swarm source root used for file editing/apply/update
      --cluster-file PATH        override the cluster file path
      --machines-dir PATH        override the machines directory
      --services-dir PATH        override the services directory
      --remote-path PATH         managed repo path on target hosts
      --nixos-dir PATH           target NixOS configuration directory

    Notes:
      - Run this from a Mix or release runtime with the ex_ratatui native library available.
      - The old one-shot CLI subcommands were removed; the TUI is now the primary operator interface.
      - Without --source, Nix-Swarm prefers NIX_SWARM_SOURCE, then a local checkout/examples root, then ~/.config/nix-swarm.
      - Without an explicit cookie option, Nix-Swarm prefers NIX_SWARM_COOKIE_FILE, then SOURCE/secrets/{nix-swarm.cookie,swarm.cookie}, then /etc/nixos/nix-swarm/secrets/nix-swarm.cookie.
    """)
  end
end
