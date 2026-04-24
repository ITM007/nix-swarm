defmodule Swarm.ThreeNodeClusterTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "swarm-three-node-#{System.unique_integer([:positive])}")
    cluster = Swarm.TestCluster.start_three_node_cluster(root)

    on_exit(fn ->
      Swarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    {:ok, cluster: cluster}
  end

  test "three node cluster supports status, diagnostics, restart, logs, and failover", %{
    cluster: cluster
  } do
    [node_a, node_b, node_c] = cluster.nodes

    status = :rpc.call(node_a, Swarm.API, :cluster_status, [])
    assert Enum.sort(status.live_nodes) == cluster.nodes
    assert Map.has_key?(status.placements, "gitea")
    assert Map.has_key?(status.placements, "proxy")

    gitea_slots = status.placements["gitea"]

    assert Enum.map(gitea_slots, & &1.owner)
           |> Enum.uniq()
           |> length() == 2

    proxy_slot = status.placements["proxy"] |> hd()
    assert proxy_slot.owner in [node_a, node_c]

    assert :ok ==
             Swarm.TestCluster.wait_until(fn ->
               converged?(cluster.root, cluster.nodes, status.placements)
             end)

    remote =
      Swarm.Remote.options!(
        target: Atom.to_string(node_b),
        cookie: Atom.to_string(Node.get_cookie())
      )

    diagnostic = Swarm.Remote.diagnose_connection(remote)

    assert diagnostic.connect_result in [true, :ignored]
    assert diagnostic.remote_probe.cluster_members.status == :ok

    overview = :rpc.call(node_b, Swarm.API, :cluster_overview, [])
    assert length(overview.status.nodes) == 3

    restart_result = :rpc.call(node_b, Swarm.API, :restart_service, ["gitea"])
    assert length(restart_result) == 2

    logs = :rpc.call(node_c, Swarm.API, :logs, ["gitea", 50])

    assert Enum.any?(logs, fn {_node, entries} ->
             Enum.any?(entries, &String.contains?(&1.logs, "restart"))
           end)

    peer_a = Swarm.TestCluster.peer_for(cluster, node_a)
    :ok = :peer.stop(peer_a)

    assert :ok ==
             Swarm.TestCluster.wait_until(fn ->
               status_after = :rpc.call(node_b, Swarm.API, :cluster_status, [])
               Enum.sort(status_after.live_nodes) == Enum.sort([node_b, node_c])
             end)

    status_after = :rpc.call(node_b, Swarm.API, :cluster_status, [])
    assert Enum.sort(status_after.live_nodes) == Enum.sort([node_b, node_c])

    assert :ok ==
             Swarm.TestCluster.wait_until(fn ->
               converged?(cluster.root, [node_b, node_c], status_after.placements)
             end)
  end

  defp converged?(root, live_nodes, placements) do
    Enum.all?(placements, fn {_service, slots} ->
      Enum.all?(slots, fn slot ->
        Enum.all?(live_nodes, fn node ->
          actual = Swarm.TestCluster.unit_state(root, node, slot.unit)
          expected = if node == slot.owner, do: "running", else: "stopped"
          actual == expected
        end)
      end)
    end)
  end
end
