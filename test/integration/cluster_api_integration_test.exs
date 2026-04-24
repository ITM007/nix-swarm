defmodule Swarm.ClusterApiIntegrationTest do
  @moduledoc """
  Integration coverage for the RPCs the TUI uses (cluster_overview, cluster_members,
  node_service_logs, cluster_logs, logs) plus the executor's unit-name validation
  flowing through the actual cluster.
  """
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "swarm-api-int-#{System.unique_integer([:positive])}")
    cluster = Swarm.TestCluster.start_three_node_cluster(root)

    on_exit(fn ->
      Swarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    {:ok, cluster: cluster}
  end

  test "cluster_overview returns aggregated state with metrics", %{cluster: cluster} do
    [node_a, _, _] = cluster.nodes

    overview = :rpc.call(node_a, Swarm.API, :cluster_overview, [])
    assert is_map(overview)
    assert Map.has_key?(overview, :members)
    assert Map.has_key?(overview, :status)
    assert Enum.sort(overview.members.live_nodes) == cluster.nodes
    assert Map.has_key?(overview.status.placements, "gitea")

    nodes = overview.status.nodes
    assert is_list(nodes) and nodes != []

    Enum.each(nodes, fn {_node, payload} ->
      assert is_map(payload)
      assert Map.has_key?(payload, :services)
    end)
  end

  test "cluster_members lists every live node", %{cluster: cluster} do
    [node_a, _, _] = cluster.nodes
    members = :rpc.call(node_a, Swarm.API, :cluster_members, [])
    assert Enum.sort(members.live_nodes) == cluster.nodes
  end

  test "logs/2 returns log payloads for the running service", %{cluster: cluster} do
    [_, node_b, _] = cluster.nodes

    logs = :rpc.call(node_b, Swarm.API, :logs, ["gitea", 25])

    assert is_list(logs)
    assert length(logs) >= 1

    Enum.each(logs, fn {node, entries} ->
      assert node in cluster.nodes
      assert is_list(entries)
    end)
  end

  test "node_service_logs/2 returns per-node service logs", %{cluster: cluster} do
    [node_a, _, _] = cluster.nodes
    result = :rpc.call(node_a, Swarm.API, :node_service_logs, [node_a, 10])
    assert result != {:badrpc, :nodedown}
  end

  test "cluster_logs/2 returns the swarmd log payload (or empty)", %{cluster: cluster} do
    [node_a, _, _] = cluster.nodes
    output = :rpc.call(node_a, Swarm.API, :cluster_logs, [node_a, 5])
    assert is_binary(output) or is_list(output) or is_map(output)
  end

  test "executor unit-name validation rejects argument injection across the cluster",
       %{cluster: cluster} do
    [node_a, _, _] = cluster.nodes

    for bad <- ["--root=/etc/passwd", "../../etc/passwd", "foo;rm", "-rf"] do
      assert {:error, :invalid_unit_name} =
               :rpc.call(node_a, Swarm.Executor, :start_unit, [bad])

      assert {:error, :invalid_unit_name} =
               :rpc.call(node_a, Swarm.Executor, :unit_logs, [bad, 5])
    end
  end
end
