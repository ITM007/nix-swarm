defmodule Swarm.API do
  @moduledoc false

  alias Swarm.Executor
  alias Swarm.Placement
  alias Swarm.Reconciler

  def local_status do
    %{
      node: Node.self(),
      live_nodes: Swarm.Cluster.live_nodes(),
      generation: Swarm.Config.runtime().generation,
      services: Reconciler.local_status()
    }
  end

  def cluster_status do
    live_nodes = Swarm.Cluster.live_nodes()

    %{
      queried_node: Node.self(),
      live_nodes: live_nodes,
      placements: Placement.plan(Swarm.Config.current(), live_nodes),
      nodes: collect_statuses(live_nodes)
    }
  end

  def cluster_members do
    %{
      queried_node: Node.self(),
      live_nodes: Swarm.Cluster.live_nodes(),
      configured_nodes: Swarm.Config.peers()
    }
  end

  def cluster_overview do
    %{
      members: cluster_members(),
      status: cluster_status()
    }
  end

  def reconcile_cluster do
    for node <- Swarm.Cluster.live_nodes() do
      rpc(node, Reconciler, :reconcile_now, [])
    end
  end

  def restart_service(service_name) do
    service_name = to_string(service_name)

    Swarm.Cluster.live_nodes()
    |> owners_for(service_name)
    |> Enum.map(fn node ->
      {node, rpc(node, __MODULE__, :restart_local_service, [service_name])}
    end)
  end

  def restart_local_service(service_name) do
    Reconciler.restart_local_service(service_name)
  end

  def logs(service_name, lines \\ 50) do
    service_name = to_string(service_name)

    Swarm.Cluster.live_nodes()
    |> owners_for(service_name)
    |> Enum.map(fn node ->
      logs =
        rpc(node, __MODULE__, :local_logs, [service_name, lines])

      {node, logs}
    end)
  end

  def local_logs(service_name, lines) do
    config = Swarm.Config.current()
    live_nodes = Swarm.Cluster.live_nodes()

    Placement.local_units(Node.self(), config, live_nodes)
    |> Enum.filter(&(&1.service == service_name))
    |> Enum.map(fn slot ->
      logs =
        case Executor.unit_logs(slot.unit, lines) do
          {:ok, output} -> output
          {:error, reason} -> inspect(reason)
        end

      %{slot: slot.slot, unit: slot.unit, logs: logs}
    end)
  end

  defp owners_for(live_nodes, service_name) do
    Swarm.Config.current()
    |> Placement.plan(live_nodes)
    |> Map.get(service_name, [])
    |> Enum.map(& &1.owner)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp collect_statuses(nodes) do
    Enum.map(nodes, fn node ->
      status =
        if node == Node.self() do
          local_status()
        else
          rpc(node, __MODULE__, :local_status, [])
        end

      {node, status}
    end)
  end

  defp rpc(node, module, function, args) do
    if node == Node.self() do
      apply(module, function, args)
    else
      :rpc.call(node, module, function, args, 5_000)
    end
  end
end
