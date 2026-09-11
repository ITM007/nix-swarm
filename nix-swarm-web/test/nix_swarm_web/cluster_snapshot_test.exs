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
    assert Enum.find(api.slots, &(&1.slot == 0)).ports == [8080]

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

  test "preserves proxy configuration and route metadata on each node" do
    payload = @fixture |> File.read!() |> :json.decode()
    snapshot = ClusterSnapshot.normalize(payload)
    proxy = Enum.find(snapshot.nodes, &(&1.name == "node-a@cluster")).proxy

    assert proxy.enabled?
    assert proxy.listen_port == 8088
    assert [%{name: "api", host: "api.example", upstreams: ["10.0.0.2:8080"]}] = proxy.routes
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

  test "keeps configured nodes visible when their status observation is missing" do
    payload = %{
      "overview" => %{
        "members" => %{
          "configured_nodes" => ["node-a@cluster", "node-b@cluster"],
          "live_nodes" => ["node-a@cluster"]
        },
        "status" => %{
          "live_nodes" => ["node-a@cluster"],
          "nodes" => [
            ["node-a@cluster", %{"node" => "node-a@cluster", "availability" => "active"}]
          ]
        }
      }
    }

    snapshot = ClusterSnapshot.normalize(payload)
    missing = Enum.find(snapshot.nodes, &(&1.name == "node-b@cluster"))

    refute snapshot.stale?
    assert Enum.map(snapshot.nodes, & &1.name) == ["node-a@cluster", "node-b@cluster"]
    assert missing.status == "down"
    assert missing.availability == "unavailable"
    assert missing.error == %{error: "node_unreachable", reason: "not_live"}
    assert Enum.any?(snapshot.errors, &(&1.node == "node-b@cluster"))
    assert snapshot.summary.configured_nodes == 2
    assert snapshot.summary.live_nodes == 1
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
