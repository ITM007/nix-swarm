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
    {opts, args, _invalid} = OptionParser.parse(argv, strict: @strict_opts)
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

    """
    `#{command}` was removed from the public command surface.

      Nix-Swarm is TUI-first in v0.1.0 alpha. Launch the console instead:
      nix-swarm --target NODE

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
    IO.puts("""
    Nix-Swarm

    Launch the operator TUI:
      nix-swarm --target NODE
      nix-swarm --target NODE --source /path/to/checkout

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
