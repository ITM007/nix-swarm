defmodule NixSwarm.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = children(role())

    require Logger
    Logger.info("Starting NixSwarm supervision tree", children: length(children))

    opts = [strategy: :rest_for_one, name: NixSwarm.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def role do
    case System.get_env("NIX_SWARM_ROLE") || Application.get_env(:nix_swarm, :role, :agent) do
      role when role in [:operator, "operator"] -> :operator
      role when role in [:agent, "agent"] -> :agent
      other -> raise ArgumentError, "invalid Nix-Swarm runtime role: #{inspect(other)}"
    end
  end

  defp children(:operator) do
    [{Task.Supervisor, name: NixSwarm.TaskSupervisor}]
  end

  defp children(:agent) do
    [
      {Task.Supervisor, name: NixSwarm.TaskSupervisor},
      {NixSwarm.Config.Server, []},
      {NixSwarm.OperationalState, []},
      {NixSwarm.Cluster, []},
      {NixSwarm.Autoscaler, []},
      {NixSwarm.Reconciler, []},
      {NixSwarm.QueryServer, []}
    ]
    |> maybe_add_watchdog()
  end

  defp maybe_add_watchdog(children) do
    if System.get_env("NOTIFY_SOCKET") do
      children ++ [{NixSwarm.Watchdog, []}]
    else
      children
    end
  end
end
