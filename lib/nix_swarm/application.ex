defmodule NixSwarm.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {NixSwarm.Executor.Server, []},
      {NixSwarm.Cluster, []},
      {NixSwarm.Reconciler, []}
    ]

    # Only start the watchdog under systemd (NOTIFY_SOCKET is set)
    children =
      if System.get_env("NOTIFY_SOCKET") do
        children ++ [{NixSwarm.Watchdog, []}]
      else
        children
      end

    require Logger
    Logger.info("Starting NixSwarm supervision tree", children: length(children))

    opts = [strategy: :one_for_one, name: NixSwarm.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
