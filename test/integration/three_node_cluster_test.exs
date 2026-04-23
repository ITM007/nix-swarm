defmodule Swarm.ThreeNodeClusterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    root = Path.join(System.tmp_dir!(), "swarm-three-node-#{System.unique_integer([:positive])}")
    cluster = Swarm.TestCluster.start_three_node_cluster(root)

    on_exit(fn ->
      Swarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    {:ok, cluster: cluster}
  end

  test "three node cluster supports status, restart, logs, and failover", %{cluster: cluster} do
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

    status_output =
      capture_io(fn ->
        Swarm.CLI.main([
          "--target",
          Atom.to_string(node_b),
          "--cookie",
          Atom.to_string(Node.get_cookie()),
          "status"
        ])
      end)

    plain_status_output = strip_ansi(status_output)

    assert plain_status_output =~ "gitea"
    assert plain_status_output =~ "proxy"
    assert plain_status_output =~ "placements"
    assert plain_status_output =~ "units"

    summary_output =
      capture_io(fn ->
        Swarm.CLI.main([
          "--target",
          Atom.to_string(node_b),
          "--cookie",
          Atom.to_string(Node.get_cookie()),
          "status",
          "--summary"
        ])
      end)

    plain_summary_output = strip_ansi(summary_output)

    assert plain_summary_output =~ "cluster summary"
    assert plain_summary_output =~ "replicas"
    assert plain_summary_output =~ "owned"
    assert plain_summary_output =~ "running"
    assert plain_summary_output =~ "gitea"
    assert plain_summary_output =~ "2"
    assert plain_summary_output =~ "2/3"

    doctor_output =
      capture_io(fn ->
        Swarm.CLI.main([
          "--target",
          Atom.to_string(node_b),
          "--cookie",
          Atom.to_string(Node.get_cookie()),
          "doctor"
        ])
      end)

    plain_doctor_output = strip_ansi(doctor_output)

    assert plain_doctor_output =~ "doctor for"
    assert plain_doctor_output =~ "distributed Erlang connection"
    assert plain_doctor_output =~ "This node is reachable for Swarm RPC."

    map_output =
      capture_io(fn ->
        Swarm.CLI.main([
          "--target",
          Atom.to_string(node_b),
          "--cookie",
          Atom.to_string(Node.get_cookie()),
          "cluster",
          "map"
        ])
      end)

    plain_map_output = strip_ansi(map_output)

    assert plain_map_output =~ "cluster map"
    assert plain_map_output =~ "gitea slot"
    assert plain_map_output =~ "proxy slot"

    members_output =
      capture_io(fn ->
        assert :ok ==
                 Swarm.CLI.run([
                   "--target",
                   Atom.to_string(node_b),
                   "--cookie",
                   Atom.to_string(Node.get_cookie()),
                   "cluster",
                   "members"
                 ])
      end)

    plain_members_output = strip_ansi(members_output)

    assert plain_members_output =~ "cluster members"
    assert plain_members_output =~ "queried node"
    assert plain_members_output =~ Atom.to_string(node_b)

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

  defp strip_ansi(output) do
    Regex.replace(~r/\e\[[\d;]*m/, output, "")
  end
end
