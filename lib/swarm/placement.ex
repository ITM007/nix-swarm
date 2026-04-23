defmodule Swarm.Placement do
  @moduledoc false

  alias Swarm.Service

  def plan(config \\ Swarm.Config.current(), live_nodes \\ Swarm.Cluster.live_nodes()) do
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

  def local_units(
        node \\ Node.self(),
        config \\ Swarm.Config.current(),
        live_nodes \\ Swarm.Cluster.live_nodes()
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
end
