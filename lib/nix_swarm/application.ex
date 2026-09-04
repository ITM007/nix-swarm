defmodule NixSwarm.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # `--version` and `--help` must be side-effect free: the packaged
    # operator wrapper calls Application.ensure_all_started(:nix_swarm)
    # before CLI.main, and booting the runtime children would log the
    # "Starting NixSwarm supervision tree" line to stdout and create paths.
    # Start an empty supervisor: satisfies the application contract
    # ({:ok, pid}) with no children and no startup log.
    if pure_invocation?() do
      Supervisor.start_link([], strategy: :rest_for_one, name: NixSwarm.Supervisor)
    else
      start_runtime()
    end
  end

  @doc """
  True when argv requests `--version` or `--help`, in which case the
  supervision tree must not boot (pure output, no side effects).
  """
  def pure_invocation?(argv \\ System.argv()) do
    "--version" in argv or "--help" in argv
  end

  defp start_runtime do
    children = children(role())

    require Logger

    unless System.get_env("NIX_SWARM_QUERY_MODE") == "1" do
      Logger.info("Starting NixSwarm supervision tree", children: length(children))
    end

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
