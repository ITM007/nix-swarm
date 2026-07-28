defmodule NixSwarm.Placement do
  @moduledoc """
  Deterministic service-placement engine.

  Ranks eligible nodes per service using a stable hash and cycles
  service slots across the ranking, spreading replicas when possible.
  """

  alias NixSwarm.Service

  @spec plan(map(), [atom()], map()) :: %{
          optional(String.t()) => [%{slot: integer(), owner: atom() | nil, unit: String.t()}]
        }
  def plan(
        config \\ NixSwarm.Config.current(),
        live_nodes \\ NixSwarm.Cluster.placement_nodes(),
        replica_targets \\ autoscaling_targets()
      ) do
    Enum.into(config.services, %{}, fn service ->
      ranked_nodes = ranked_eligible_nodes(service, live_nodes, config.nodes)
      replicas = effective_replicas(service, replica_targets)

      slots = assign_slots(service, ranked_nodes, replicas)

      {service.name, slots}
    end)
  end

  @spec diagnostics(map(), [atom()]) :: [map()]
  def diagnostics(
        config \\ NixSwarm.Config.current(),
        live_nodes \\ NixSwarm.Cluster.placement_nodes()
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

  @spec local_units(atom(), map(), [atom()], map()) :: [map()]
  def local_units(
        node \\ Node.self(),
        config \\ NixSwarm.Config.current(),
        live_nodes \\ NixSwarm.Cluster.placement_nodes(),
        replica_targets \\ autoscaling_targets()
      ) do
    plan(config, live_nodes, replica_targets)
    |> Enum.flat_map(fn {service_name, slots} ->
      Enum.map(slots, fn slot ->
        Map.put(slot, :service, service_name)
      end)
    end)
    |> Enum.filter(&(&1.owner == node))
  end

  @spec owner_for_slot([atom()], integer()) :: atom() | nil
  def owner_for_slot([], _slot), do: nil

  def owner_for_slot(ranked_nodes, slot),
    do: Enum.at(ranked_nodes, rem(slot, length(ranked_nodes)))

  @doc "Returns the temporary deterministic autoscaler owner for a service."
  def scaler_owner(service, nodes, node_info) do
    service
    |> ranked_eligible_nodes(nodes, node_info)
    |> List.first()
  end

  defp assign_slots(service, ranked_nodes, replicas) do
    max_per_node = service.max_replicas_per_node

    {slots, _counts} =
      Enum.map_reduce(Service.slots(service, replicas), %{}, fn slot, counts ->
        owner = capped_owner_for_slot(ranked_nodes, slot, counts, max_per_node)
        counts = if owner, do: Map.update(counts, owner, 1, &(&1 + 1)), else: counts

        {%{slot: slot, owner: owner, unit: Service.unit_name(service, slot)}, counts}
      end)

    slots
  end

  defp capped_owner_for_slot([], _slot, _counts, _max_per_node), do: nil
  defp capped_owner_for_slot(nodes, slot, _counts, nil), do: owner_for_slot(nodes, slot)

  defp capped_owner_for_slot(nodes, slot, counts, max_per_node) do
    nodes
    |> rotate(rem(slot, length(nodes)))
    |> Enum.find(fn node -> Map.get(counts, node, 0) < max_per_node end)
  end

  defp rotate(nodes, 0), do: nodes
  defp rotate(nodes, offset), do: Enum.drop(nodes, offset) ++ Enum.take(nodes, offset)

  defp effective_replicas(%{autoscaling: %{enabled: true} = policy} = service, targets) do
    targets
    |> Map.get(service.name, service.replicas)
    |> max(policy.min_replicas)
    |> min(policy.max_replicas)
  end

  defp effective_replicas(service, _targets), do: service.replicas

  defp autoscaling_targets do
    if Process.whereis(NixSwarm.Autoscaler), do: NixSwarm.Autoscaler.targets(), else: %{}
  catch
    :exit, _reason -> %{}
  end

  defp eligible_nodes(service, nodes, node_info) do
    nodes
    |> Enum.filter(&eligible_node?(service, &1, node_info))
    |> Enum.sort()
  end

  defp ranked_eligible_nodes(service, live_nodes, node_info) do
    preferred_indexes =
      service.preferred_nodes
      |> Enum.with_index()
      |> Map.new()

    live_nodes
    |> Enum.filter(&eligible_node?(service, &1, node_info))
    |> Enum.sort_by(fn node ->
      score = stable_score(service.name, node)
      preferred_rank = Map.get(preferred_indexes, node, map_size(preferred_indexes))
      {preferred_rank, -score, Atom.to_string(node)}
    end)
  end

  defp stable_score(service_name, node) do
    <<score::unsigned-integer-size(64), _rest::binary>> =
      :crypto.hash(:sha256, [service_name, <<0>>, Atom.to_string(node)])

    score
  end

  defp eligible_node?(service, node, node_info) do
    allowed_nodes = Map.get(service, :allowed_nodes, [])
    metadata = Map.get(node_info, node, %{labels: MapSet.new(), availability: :active})

    (allowed_nodes == [] or node in allowed_nodes) and
      Map.get(metadata, :availability, :active) == :active and
      Service.eligible?(service, metadata)
  end

  defp maybe_add_invalid_replica_count(diagnostics, %{replicas: replicas} = service)
       when replicas < 0 do
    [
      %{
        service: service.name,
        severity: :error,
        reason: :invalid_replica_count,
        message: "#{service.name}: replicas must be zero or greater"
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
