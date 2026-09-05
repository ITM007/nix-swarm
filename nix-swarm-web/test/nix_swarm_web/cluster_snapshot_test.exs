defmodule NixSwarmWeb.ClusterSnapshotTest do
  use ExUnit.Case, async: true

  alias NixSwarmWeb.ClusterSnapshot

  @fixture Path.expand("../fixtures/operator_snapshot.json", __DIR__)

  test "normalizes JSON tuples and preserves partial cluster state" do
    payload = @fixture |> File.read!() |> :json.decode()
    snapshot = ClusterSnapshot.normalize(payload)

    assert %DateTime{} = snapshot.captured_at
    assert snapshot.queried_node == "node-a@cluster"
    refute snapshot.stale?

    assert Enum.map(snapshot.nodes, & &1.name) == [
             "node-a@cluster",
             "node-b@cluster",
             "node-c@cluster"
           ]

    assert Enum.find(snapshot.nodes, &(&1.name == "node-c@cluster"))
           |> Map.merge(%{status: "down"})
           |> Map.get(:status) == "down"

    api = Enum.find(snapshot.services, &(&1.name == "api"))
    assert api.desired_replicas == 2
    assert Enum.any?(api.slots, &(&1.status == "awaiting_heal"))
    assert Enum.any?(api.slots, &is_nil(&1.owner))

    assert snapshot.drift.config_consistent? == false
    assert snapshot.drift.digests == %{"node-a@cluster" => "aaa111", "node-b@cluster" => "bbb222"}
    assert Enum.any?(snapshot.drift.diagnostics, &(&1.reason == "unplaced_slot"))
    assert Enum.any?(snapshot.drift.versions, &(&1 == {"1.9.0", ["node-b@cluster"]}))
    assert Enum.any?(snapshot.errors, &(&1.node == "node-c@cluster"))
  end

  test "derives stable summaries and ownership graph in deterministic order" do
    payload = @fixture |> File.read!() |> :json.decode()
    snapshot = ClusterSnapshot.normalize(payload)

    assert snapshot.summary == %{
             configured_nodes: 3,
             live_nodes: 2,
             placement_nodes: 2,
             services: 2,
             running_services: 2,
             degraded_services: 1,
             awaiting_heal_services: 1
           }

    assert Enum.map(snapshot.graph.nodes, & &1.name) == [
             "node-a@cluster",
             "node-b@cluster",
             "node-c@cluster"
           ]

    assert Enum.any?(snapshot.graph.ownership_edges, fn edge ->
             edge.service == "api" and edge.slot == 0 and edge.owner == "node-a@cluster"
           end)

    assert snapshot.metrics.cluster.cpu.used == 3
    assert snapshot.metrics.cluster.cpu.total == 8
    assert snapshot.metrics.nodes["node-b@cluster"].network.received == 800
    assert snapshot.metrics.services["worker"].memory == 9
  end

  test "keeps unknown values explicit instead of manufacturing healthy data" do
    snapshot = ClusterSnapshot.normalize(%{"overview" => %{"members" => %{}, "status" => %{}}})

    assert snapshot.queried_node == "unknown"
    assert snapshot.nodes == []
    assert snapshot.services == []
    assert snapshot.drift.config_consistent? == nil
    assert snapshot.summary.live_nodes == 0
    assert snapshot.metrics.cluster.cpu.status == "unknown"
  end

  test "infers consistency only when every reported digest is known and equal" do
    payload = %{
      "overview" => %{
        "members" => %{"configured_nodes" => ["a@h", "b@h"], "live_nodes" => ["a@h", "b@h"]},
        "status" => %{
          "config_digests" => %{"a@h" => "same", "b@h" => "same"},
          "nodes" => []
        }
      }
    }

    assert ClusterSnapshot.normalize(payload).drift.config_consistent? == true

    unknown = put_in(payload, ["overview", "status", "config_digests", "b@h"], "unknown")
    assert ClusterSnapshot.normalize(unknown).drift.config_consistent? == false
  end
end
