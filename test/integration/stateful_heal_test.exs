defmodule NixSwarm.StatefulHealTest do
  use ExUnit.Case, async: false

  test "manual heal restores state before starting the service and fences the old owner" do
    root =
      Path.join(
        System.tmp_dir!(),
        "nix-swarm-stateful-heal-#{System.unique_integer([:positive])}"
      )

    state_dir = Path.join(root, "state/db")
    snapshot_dir = Path.join(root, "backups/db/latest")

    service = %{
      name: "db",
      replicas: 1,
      unit_template: "db.service",
      constraints: ["ssd"],
      state: %{
        dirs: [state_dir],
        backup: %{schedule: "hourly", target: "file:///backups/db"},
        restore: "borg-latest",
        auto_heal: false,
        heal_grace_sec: 600
      }
    }

    cluster = NixSwarm.TestCluster.start_three_node_cluster(root, [service])

    on_exit(fn ->
      NixSwarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    File.mkdir_p!(snapshot_dir)
    File.write!(Path.join(snapshot_dir, "marker.txt"), "state-from-backup\n")

    restore_script = write_restore_script!(root)
    systemctl_script = write_systemctl_script!(root)
    initial_status = :rpc.call(hd(cluster.nodes), NixSwarm.API, :cluster_status, [])
    initial_owner = initial_status.placements["db"] |> hd() |> Map.fetch!(:owner)

    assert :ok =
             NixSwarm.TestCluster.wait_until(fn ->
               status = :rpc.call(hd(cluster.nodes), NixSwarm.API, :cluster_status, [])

               Enum.any?(status.nodes, fn {_node, node_status} ->
                 Enum.any?(node_status.services, fn service_status ->
                   service_status.name == "db" and service_status.awaiting_heal == ["db.service"]
                 end)
               end)
             end)

    assert Enum.all?(cluster.nodes, fn node ->
             NixSwarm.TestCluster.unit_state(root, node, "db.service") == "stopped"
           end)

    :ok = :peer.stop(NixSwarm.TestCluster.peer_for(cluster, initial_owner))
    query_node = Enum.find(cluster.nodes, &(&1 != initial_owner))

    assert :ok =
             NixSwarm.TestCluster.wait_until(fn ->
               status = :rpc.call(query_node, NixSwarm.API, :cluster_status, [])

               Enum.sort(status.live_nodes) == Enum.sort(cluster.nodes -- [initial_owner]) and
                 Enum.sort(status.placement_nodes) == Enum.sort(cluster.nodes -- [initial_owner])
             end)

    failed_status = :rpc.call(query_node, NixSwarm.API, :cluster_status, [])
    target_node = failed_status.placements["db"] |> hd() |> Map.fetch!(:owner)
    assert target_node != initial_owner

    remote = NixSwarm.TestCluster.remote_for(cluster, query_node)

    assert :ok =
             NixSwarm.CLI.run(
               [
                 "cluster",
                 "heal",
                 "db",
                 "--yes",
                 "--target",
                 Atom.to_string(query_node),
                 "--node",
                 Atom.to_string(target_node)
               ],
               query_fun: remote.query_fun,
               command_fun:
                 local_heal_command_fun(
                   cluster,
                   target_node,
                   snapshot_dir,
                   restore_script,
                   systemctl_script
                 )
             )

    assert File.read!(Path.join(state_dir, "marker.txt")) == "state-from-backup\n"
    refute File.exists?(state_dir <> ".restore-tmp")

    assert :ok =
             NixSwarm.TestCluster.wait_until(fn ->
               Enum.all?(cluster.nodes -- [initial_owner], fn node ->
                 expected = if node == target_node, do: "running", else: "stopped"
                 NixSwarm.TestCluster.unit_state(root, node, "db.service") == expected
               end)
             end)

    {rejoined_peer, rejoined_node} = NixSwarm.TestCluster.restart_peer(cluster, initial_owner)

    on_exit(fn ->
      try do
        :peer.stop(rejoined_peer)
      catch
        _, _ -> :ok
      end
    end)

    assert rejoined_node == initial_owner

    assert :ok =
             NixSwarm.TestCluster.wait_until(fn ->
               status = :rpc.call(target_node, NixSwarm.API, :cluster_status, [])
               initial_owner in status.live_nodes
             end)

    assert :ok =
             NixSwarm.TestCluster.wait_until(fn ->
               Enum.count(cluster.nodes, fn node ->
                 NixSwarm.TestCluster.unit_state(root, node, "db.service") == "running"
               end) == 1 and
                 NixSwarm.TestCluster.unit_state(root, target_node, "db.service") == "running" and
                 NixSwarm.TestCluster.unit_state(root, initial_owner, "db.service") == "stopped"
             end)
  end

  defp write_restore_script!(root) do
    path = Path.join(root, "restore-db.sh")

    File.write!(path, """
    #!/bin/sh
    set -eu
    cp -R "$SNAPSHOT_DIR/." "$1"
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp write_systemctl_script!(root) do
    path = Path.join(root, "systemctl.sh")

    File.write!(path, """
    #!/bin/sh
    set -eu
    case "$1" in
      start)
        printf 'running\\n' > "$UNIT_STATE_FILE"
        ;;
      is-active)
        test "$(cat "$UNIT_STATE_FILE")" = running
        ;;
      *)
        exit 2
        ;;
    esac
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp local_heal_command_fun(
         cluster,
         target_node,
         snapshot_dir,
         restore_script,
         systemctl_script
       ) do
    fn "ssh", args ->
      {_, ["--", host, command]} = Enum.split_while(args, &(&1 != "--"))
      expected_host = cluster.config.nodes[target_node].deploy_host
      assert host == expected_host

      unit_state_file =
        Path.join([
          cluster.root,
          NixSwarm.Executor.Fake.sanitize_node_name(target_node),
          "db.service.state"
        ])

      command =
        command
        |> String.replace(
          "/run/current-system/sw/bin/nix-swarm-restore-db",
          restore_script
        )
        |> String.replace("systemctl", systemctl_script)

      System.cmd(
        "sh",
        ["-c", command],
        env: [
          {"SNAPSHOT_DIR", snapshot_dir},
          {"UNIT_STATE_FILE", unit_state_file}
        ],
        stderr_to_stdout: true
      )
    end
  end
end
