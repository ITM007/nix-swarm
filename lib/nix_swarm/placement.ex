defmodule NixSwarm.Placement do
  @moduledoc """
  Deterministic service-placement engine.

  Active nodes are sorted by a stable service/node hash and slots cycle through
  that ordering. This gives a repeatable spread without exposing scheduling
  labels or per-node capacity controls in service configuration.
  """

  alias NixSwarm.Service

  @spec plan(map(), [atom()], map()) :: %{optional(String.t()) => [map()]}
  def plan(
        config \\ NixSwarm.Config.current(),
        live_nodes \\ NixSwarm.Cluster.placement_nodes(),
        replica_targets \\ autoscaling_targets()
      ) do
    Enum.into(config.services, %{}, fn service ->
      nodes = ranked_eligible_nodes(service, live_nodes, config.nodes)
      replicas = effective_replicas(service, replica_targets)
      {service.name, assign_slots(service, nodes, replicas)}
    end)
  end

  @spec diagnostics(map(), [atom()]) :: [map()]
  def diagnostics(
        config \\ NixSwarm.Config.current(),
        live_nodes \\ NixSwarm.Cluster.placement_nodes()
      ) do
    placement = plan(config, live_nodes)

    Enum.flat_map(config.services, fn service ->
      configured_nodes = eligible_nodes(service, config.peers, config.nodes)
      live_nodes_for_service = eligible_nodes(service, live_nodes, config.nodes)
      slots = Map.get(placement, service.name, [])
      unowned_slots = slots |> Enum.filter(&is_nil(&1.owner)) |> Enum.map(& &1.slot)

      []
      |> maybe_add_invalid_replica_count(service)
      |> maybe_add_no_configured_eligible_nodes(service, configured_nodes)
      |> maybe_add_no_live_eligible_nodes(service, configured_nodes, live_nodes_for_service)
      |> maybe_add_unowned_slots(service, unowned_slots)
      |> maybe_add_underspread_replicas(service, live_nodes_for_service)
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
      Enum.map(slots, &Map.put(&1, :service, service_name))
    end)
    |> Enum.filter(&(&1.owner == node))
  end

  @spec owner_for_slot([atom()], integer()) :: atom() | nil
  def owner_for_slot([], _slot), do: nil
  def owner_for_slot(nodes, slot), do: Enum.at(nodes, rem(slot, length(nodes)))

  @doc "Returns the temporary deterministic autoscaler owner for a service."
  def scaler_owner(service, nodes, node_info) do
    service |> ranked_eligible_nodes(nodes, node_info) |> List.first()
  end

  defp assign_slots(service, nodes, replicas) do
    Enum.map(Service.slots(service, replicas), fn slot ->
      %{slot: slot, owner: owner_for_slot(nodes, slot), unit: Service.unit_name(service, slot)}
    end)
  end

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
    nodes |> Enum.filter(&eligible_node?(service, &1, node_info)) |> Enum.sort()
  end

  defp ranked_eligible_nodes(service, live_nodes, node_info) do
    live_nodes
    |> Enum.filter(&eligible_node?(service, &1, node_info))
    |> Enum.sort_by(fn node -> {-stable_score(service.name, node), Atom.to_string(node)} end)
  end

  defp stable_score(service_name, node) do
    <<score::unsigned-integer-size(64), _rest::binary>> =
      :crypto.hash(:sha256, [service_name, <<0>>, Atom.to_string(node)])

    score
  end

  defp eligible_node?(service, node, node_info) do
    allowed_nodes = Map.get(service, :allowed_nodes, [])
    metadata = Map.get(node_info, node, %{availability: :active})

    (allowed_nodes == [] or node in allowed_nodes) and
      Map.get(metadata, :availability, :active) == :active
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
        reason: :no_eligible_nodes,
        allowed_nodes: service.allowed_nodes,
        message: "#{service.name}: no configured active nodes are eligible"
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
        configured_eligible_nodes: configured_nodes,
        message: "#{service.name}: configured nodes are unavailable"
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

  defp maybe_add_underspread_replicas(diagnostics, service, nodes)
       when service.replicas > length(nodes) and length(nodes) > 0 do
    [
      %{
        service: service.name,
        severity: :warning,
        reason: :replicas_exceed_live_eligible_nodes,
        replicas: service.replicas,
        live_eligible_nodes: nodes,
        message:
          "#{service.name}: #{service.replicas} replicas requested but only #{length(nodes)} eligible live nodes are available"
      }
      | diagnostics
    ]
  end

  defp maybe_add_underspread_replicas(diagnostics, _service, _nodes), do: diagnostics
end
