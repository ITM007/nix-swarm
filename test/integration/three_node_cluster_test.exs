defmodule NixSwarm.ThreeNodeClusterTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-three-node-#{System.unique_integer([:positive])}")

    cluster = NixSwarm.TestCluster.start_three_node_cluster(root)

    on_exit(fn ->
      NixSwarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    {:ok, cluster: cluster}
  end

  test "three node cluster supports status, diagnostics, service control, machine control, logs, and failover",
       %{
         cluster: cluster
       } do
    [node_a, node_b, node_c] = cluster.nodes

    status = :rpc.call(node_a, NixSwarm.API, :cluster_status, [])
    assert Enum.sort(status.live_nodes) == cluster.nodes
    assert status.placement_diagnostics == []
    assert Map.has_key?(status.placements, "gitea")
    assert Map.has_key?(status.placements, "proxy")

    gitea_slots = status.placements["gitea"]

    assert Enum.map(gitea_slots, & &1.owner)
           |> Enum.uniq()
           |> length() == 2

    proxy_slot = status.placements["proxy"] |> hd()
    assert proxy_slot.owner in [node_a, node_c]

    assert :ok ==
             NixSwarm.TestCluster.wait_until(fn ->
               converged?(cluster.root, cluster.nodes, status.placements)
             end)

    remote =
      NixSwarm.Remote.options!(
        target: Atom.to_string(node_b),
        cookie: Atom.to_string(Node.get_cookie())
      )

    diagnostic = NixSwarm.Remote.diagnose_connection(remote)

    assert diagnostic.connect_result in [true, :ignored]
    assert diagnostic.remote_probe.cluster_members.status == :ok

    overview = :rpc.call(node_b, NixSwarm.API, :cluster_overview, [])
    assert length(overview.status.nodes) == 3

    stop_result = :rpc.call(node_b, NixSwarm.API, :stop_service, ["gitea"])
    assert length(stop_result) == 3

    assert :ok ==
             NixSwarm.TestCluster.wait_until(fn ->
               service_stopped?(cluster, "gitea")
             end)

    start_result = :rpc.call(node_b, NixSwarm.API, :start_service, ["gitea"])
    assert length(start_result) == 3

    assert :ok ==
             NixSwarm.TestCluster.wait_until(fn ->
               status_after_start = :rpc.call(node_b, NixSwarm.API, :cluster_status, [])
               converged?(cluster.root, cluster.nodes, status_after_start.placements)
             end)

    restart_result = :rpc.call(node_b, NixSwarm.API, :restart_service, ["gitea"])
    assert length(restart_result) == 2

    logs = :rpc.call(node_c, NixSwarm.API, :logs, ["gitea", 50])

    assert Enum.any?(logs, fn {_node, entries} ->
             Enum.any?(entries, &String.contains?(&1.logs, "restart"))
           end)

    assert :ok = :rpc.call(node_b, NixSwarm.API, :restart_machine, [node_c])

    assert :ok ==
             NixSwarm.TestCluster.wait_until(fn ->
               cluster.root
               |> NixSwarm.TestCluster.machine_actions(node_c)
               |> Enum.any?(&String.contains?(&1, "restart"))
             end)

    assert :ok = :rpc.call(node_b, NixSwarm.API, :shutdown_machine, [node_b])

    assert :ok ==
             NixSwarm.TestCluster.wait_until(fn ->
               cluster.root
               |> NixSwarm.TestCluster.machine_actions(node_b)
               |> Enum.any?(&String.contains?(&1, "shutdown"))
             end)

    peer_a = NixSwarm.TestCluster.peer_for(cluster, node_a)
    :ok = :peer.stop(peer_a)

    assert :ok ==
             NixSwarm.TestCluster.wait_until(fn ->
               status_after = :rpc.call(node_b, NixSwarm.API, :cluster_status, [])
               Enum.sort(status_after.live_nodes) == Enum.sort([node_b, node_c])
             end)

    status_after = :rpc.call(node_b, NixSwarm.API, :cluster_status, [])
    assert Enum.sort(status_after.live_nodes) == Enum.sort([node_b, node_c])

    assert :ok ==
             NixSwarm.TestCluster.wait_until(fn ->
               converged?(cluster.root, [node_b, node_c], status_after.placements)
             end)
  end

  test "lightweight diagnostics skip noisy port probes during steady-state refreshes", %{
    cluster: cluster
  } do
    [_, node_b, _] = cluster.nodes

    remote =
      NixSwarm.Remote.options!(
        target: Atom.to_string(node_b),
        cookie: Atom.to_string(Node.get_cookie())
      )

    diagnostic = NixSwarm.Remote.diagnose_connection(remote, skip_port_checks: true)

    assert diagnostic.connect_result in [true, :ignored]
    assert diagnostic.target_port_checks == []
    assert diagnostic.remote_probe.cluster_members.status == :ok
  end

  defp service_stopped?(cluster, service_name) do
    status = :rpc.call(hd(cluster.nodes), NixSwarm.API, :cluster_status, [])

    status.placements
    |> Map.get(service_name, [])
    |> Enum.all?(fn slot ->
      Enum.all?(cluster.nodes, fn node ->
        NixSwarm.TestCluster.unit_state(cluster.root, node, slot.unit) == "stopped"
      end)
    end)
  end

  defp converged?(root, live_nodes, placements) do
    Enum.all?(placements, fn {_service, slots} ->
      Enum.all?(slots, fn slot ->
        Enum.all?(live_nodes, fn node ->
          actual = NixSwarm.TestCluster.unit_state(root, node, slot.unit)
          expected = if node == slot.owner, do: "running", else: "stopped"
          actual == expected
        end)
      end)
    end)
  end
end
