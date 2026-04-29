defmodule NixSwarm.Placement do
  @moduledoc false

  alias NixSwarm.Service

  def plan(config \\ NixSwarm.Config.current(), live_nodes \\ NixSwarm.Cluster.live_nodes()) do
    Enum.into(config.services, %{}, fn service ->
      ranked_nodes = ranked_eligible_nodes(service, live_nodes, config.nodes)

      slots =
        for slot <- Service.slots(service) do
          owner = owner_for_slot(ranked_nodes, slot)

          %{
            slot: slot,
            owner: owner,
            unit: Service.unit_name(service, slot)
          }
        end

      {service.name, slots}
    end)
  end

  def diagnostics(
        config \\ NixSwarm.Config.current(),
        live_nodes \\ NixSwarm.Cluster.live_nodes()
      ) do
    placement = plan(config, live_nodes)

    config.services
    |> Enum.flat_map(fn service ->
      configured_eligible_nodes = eligible_nodes(service, config.peers, config.nodes)
      live_eligible_nodes = eligible_nodes(service, live_nodes, config.nodes)
      slots = Map.get(placement, service.name, [])
      unowned_slots = slots |> Enum.filter(&is_nil(&1.owner)) |> Enum.map(& &1.slot)

      []
      |> maybe_add_invalid_replica_count(service)
      |> maybe_add_no_configured_eligible_nodes(service, configured_eligible_nodes)
      |> maybe_add_no_live_eligible_nodes(service, configured_eligible_nodes, live_eligible_nodes)
      |> maybe_add_unowned_slots(service, unowned_slots)
      |> maybe_add_underspread_replicas(service, live_eligible_nodes)
      |> Enum.reverse()
    end)
  end

  def local_units(
        node \\ Node.self(),
        config \\ NixSwarm.Config.current(),
        live_nodes \\ NixSwarm.Cluster.live_nodes()
      ) do
    plan(config, live_nodes)
    |> Enum.flat_map(fn {service_name, slots} ->
      Enum.map(slots, fn slot ->
        Map.put(slot, :service, service_name)
      end)
    end)
    |> Enum.filter(&(&1.owner == node))
  end

  def owner_for_slot([], _slot), do: nil

  def owner_for_slot(ranked_nodes, slot),
    do: Enum.at(ranked_nodes, rem(slot, length(ranked_nodes)))

  defp eligible_nodes(service, nodes, node_info) do
    nodes
    |> Enum.filter(fn node ->
      service
      |> Service.eligible?(Map.get(node_info, node, %{labels: MapSet.new()}))
    end)
    |> Enum.sort()
  end

  defp ranked_eligible_nodes(service, live_nodes, node_info) do
    preferred_indexes =
      service.preferred_nodes
      |> Enum.with_index()
      |> Map.new()

    live_nodes
    |> Enum.filter(fn node ->
      service
      |> Service.eligible?(Map.get(node_info, node, %{labels: MapSet.new()}))
    end)
    |> Enum.sort_by(fn node ->
      score = :erlang.phash2({service.name, node}, 1_073_741_824)
      preferred_rank = Map.get(preferred_indexes, node, map_size(preferred_indexes))
      {preferred_rank, -score, Atom.to_string(node)}
    end)
  end

  defp maybe_add_invalid_replica_count(diagnostics, %{replicas: replicas} = service)
       when replicas <= 0 do
    [
      %{
        service: service.name,
        severity: :error,
        reason: :invalid_replica_count,
        message: "#{service.name}: replicas must be greater than 0"
      }
      | diagnostics
    ]
  end

  defp maybe_add_invalid_replica_count(diagnostics, _service), do: diagnostics

  defp maybe_add_no_configured_eligible_nodes(diagnostics, service, []) do
    [
      %{
        service: service.name,
        severity: :error,
        reason: :no_configured_eligible_nodes,
        constraints: service.constraints,
        message:
          "#{service.name}: no configured nodes match constraints #{inspect(service.constraints)}"
      }
      | diagnostics
    ]
  end

  defp maybe_add_no_configured_eligible_nodes(diagnostics, _service, _nodes), do: diagnostics

  defp maybe_add_no_live_eligible_nodes(diagnostics, service, configured_nodes, [])
       when configured_nodes != [] do
    [
      %{
        service: service.name,
        severity: :error,
        reason: :no_live_eligible_nodes,
        constraints: service.constraints,
        configured_eligible_nodes: configured_nodes,
        message:
          "#{service.name}: configured nodes match constraints #{inspect(service.constraints)}, but none are live"
      }
      | diagnostics
    ]
  end

  defp maybe_add_no_live_eligible_nodes(diagnostics, _service, _configured_nodes, _live_nodes),
    do: diagnostics

  defp maybe_add_unowned_slots(diagnostics, _service, []), do: diagnostics

  defp maybe_add_unowned_slots(diagnostics, service, slots) do
    [
      %{
        service: service.name,
        severity: :error,
        reason: :unowned_slots,
        slots: slots,
        message: "#{service.name}: slots #{inspect(slots)} have no live owner"
      }
      | diagnostics
    ]
  end

  defp maybe_add_underspread_replicas(diagnostics, service, live_eligible_nodes)
       when service.replicas > length(live_eligible_nodes) and length(live_eligible_nodes) > 0 do
    [
      %{
        service: service.name,
        severity: :warning,
        reason: :replicas_exceed_live_eligible_nodes,
        replicas: service.replicas,
        live_eligible_nodes: live_eligible_nodes,
        message:
          "#{service.name}: #{service.replicas} replicas requested but only #{length(live_eligible_nodes)} eligible live nodes are available"
      }
      | diagnostics
    ]
  end

  defp maybe_add_underspread_replicas(diagnostics, _service, _live_eligible_nodes),
    do: diagnostics
end
