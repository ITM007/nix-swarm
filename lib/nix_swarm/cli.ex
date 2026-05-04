defmodule NixSwarm.CLI do
  @moduledoc false

  @strict_opts [
    help: :boolean,
    target: :string,
    cookie: :string,
    cookie_file: :string,
    name: :string,
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
    maybe_warn_cookie(opts)

    cond do
      Keyword.get(opts, :help, false) ->
        print_help()
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

  defp legacy_command_error(args) do
    command = Enum.join(args, " ")
    launch = NixSwarm.operator_launch()

    """
    `#{command}` was removed from the public command surface.

      Nix-Swarm is TUI-first in #{NixSwarm.release_label()} alpha. Launch the console instead:
      #{launch}

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
      #{launch}
      #{launch} --source /path/to/checkout

    Required:
      --target NODE              remote Nix-Swarm node to connect to

    Remote connection options:
      --cookie VALUE             explicit Erlang cookie (discouraged; visible in `ps`)
      --cookie-file PATH         read the cookie from a file
      --name NAME@HOST           override the local control node name when longnames need a reachable LAN address

    TUI options:
      --lines N                  default log line count (default: 50)
      --refresh-ms N             auto-refresh interval in milliseconds (default: 3000)
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
      - Set NIX_SWARM_COOKIE_FILE once in your shell to keep launches short.
    """)
  end
end
