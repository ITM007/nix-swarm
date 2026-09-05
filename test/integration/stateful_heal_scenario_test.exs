defmodule NixSwarm.StatefulHealScenarioTest do
  use ExUnit.Case, async: false

  alias NixSwarm.TestCluster

  @restore_wrapper "/run/current-system/sw/bin/nix-swarm-restore-db"
  @nodes [:"node-a@127.0.0.1", :"node-b@127.0.0.1", :"node-c@127.0.0.1"]

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "nix-swarm-heal-scenario-#{System.unique_integer([:positive])}"
      )

    state_dir = Path.join(root, "state/db")
    snapshot_dir = Path.join(root, "backups/db/latest")
    bin_dir = Path.join(root, "emulated-bin")

    db_service = %{
      name: "db",
      replicas: 1,
      unit_template: "db.service",
      constraints: ["ssd"],
      state: %{
        dirs: [state_dir],
        restore: "borg-latest",
        auto_heal: false,
        heal_grace_sec: 600,
        backup: %{target: "ssh://borg@backup/./db", schedule: "hourly"}
      }
    }

    cluster = TestCluster.start_three_node_cluster(root, [db_service])

    # Created after the cluster booted: start_three_node_cluster rm_rf!s root.
    File.mkdir_p!(snapshot_dir)
    File.write!(Path.join(snapshot_dir, "marker.txt"), "data-42\n")

    File.mkdir_p!(bin_dir)
    restore_emu = Path.join(bin_dir, "nix-swarm-restore-db")
    systemctl_emu = Path.join(bin_dir, "systemctl")

    File.write!(restore_emu, """
    #!/bin/sh
    staging="$1"
    [ -n "$staging" ] || exit 1
    mkdir -p "$staging"
    cp -a "$SNAPSHOT_DIR"/. "$staging"/
    """)

    File.write!(systemctl_emu, """
    #!/bin/sh
    action="$1"
    unit=""
    for arg in "$@"; do
      case "$arg" in
        -*|"$action") ;;
        *) unit="$arg" ;;
      esac
    done
    [ -n "$unit" ] || exit 0
    state_file="$UNIT_STATE_FILE"
    case "$action" in
      start) printf 'running\\n' > "$state_file" ;;
      stop) printf 'stopped\\n' > "$state_file" ;;
      is-active) [ "$(cat "$state_file" 2>/dev/null)" = "running" ] ;;
      *) exit 0 ;;
    esac
    """)

    File.chmod!(restore_emu, 0o755)
    File.chmod!(systemctl_emu, 0o755)

    on_exit(fn ->
      TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    unit_state_files =
      Map.new(@nodes, fn node ->
        host = "root@" <> (node |> Atom.to_string() |> String.split("@") |> hd())

        path =
          Path.join([root, NixSwarm.Executor.Fake.sanitize_node_name(node), "db.service.state"])

        {host, path}
      end)

    %{
      root: root,
      state_dir: state_dir,
      snapshot_dir: snapshot_dir,
      restore_emu: restore_emu,
      systemctl_emu: systemctl_emu,
      cluster: cluster,
      unit_state_files: unit_state_files
    }
  end

  defp db_owner(status) do
    case status.placements["db"] do
      [slot | _] -> slot.owner
      _ -> nil
    end
  end

  defp db_service_on(status, node) do
    Enum.find_value(status.nodes, fn
      {current, node_map} when current == node ->
        node_map |> Map.get(:services, []) |> Enum.find(&(&1.name == "db"))

      _entry ->
        nil
    end)
  end

  defp fetch_status(anchor), do: :rpc.call(anchor, NixSwarm.API, :cluster_status, [])

  defp owner_awaiting_heal(anchor) do
    status = fetch_status(anchor)

    case db_owner(status) do
      nil ->
        false

      owner_node ->
        service = db_service_on(status, owner_node)
        service != nil and service.awaiting_heal == ["db.service"]
    end
  end

  defp owner_serving(anchor) do
    status = fetch_status(anchor)

    case db_owner(status) do
      nil ->
        false

      owner_node ->
        (db_service_on(status, owner_node) || %{}) |> Map.get(:awaiting_heal, []) == []
    end
  end

  defp rewrite_remote_command(command, restore_emu, systemctl_emu) do
    command
    |> String.replace(@restore_wrapper, restore_emu)
    |> String.replace("systemctl", systemctl_emu)
  end

  defp heal_command_fun(ctx) do
    fn "ssh", args ->
      case Enum.split_while(args, &(&1 != "--")) do
        {_ssh_options, ["--", host, command]} ->
          env = [
            {"SNAPSHOT_DIR", ctx.snapshot_dir},
            {"UNIT_STATE_FILE", Map.fetch!(ctx.unit_state_files, host)}
          ]

          rewritten = rewrite_remote_command(command, ctx.restore_emu, ctx.systemctl_emu)
          System.cmd("sh", ["-c", rewritten], env: env, stderr_to_stdout: true)

        _ ->
          {"unexpected ssh invocation: #{inspect(args)}", 1}
      end
    end
  end

  test "stateful unit is held awaiting heal, recovers onto a survivor, and never double-runs",
       ctx do
    cluster = ctx.cluster
    [node_a, node_b, node_c] = cluster.nodes
    anchor = node_c

    # The stateful unit is assigned to exactly one owner but is never started
    # while its declared state directory is absent.
    assert :ok = TestCluster.wait_until(fn -> owner_awaiting_heal(anchor) end)

    # Simulate owner loss: the current owner dies before any heal happened.
    owner = db_owner(fetch_status(anchor))
    assert owner in [node_a, node_b, node_c]
    :ok = :peer.stop(TestCluster.peer_for(cluster, owner))

    assert :ok =
             TestCluster.wait_until(fn ->
               status = fetch_status(anchor)
               status.live_nodes |> length() == 2 and owner_awaiting_heal(anchor)
             end)

    # Operator runs `cluster heal db` against a survivor; the CLI resolves
    # placement through the live cluster's read-only API, then the real
    # restore-verified executor runs against the survivor host.
    query_fun = TestCluster.remote_for(cluster, anchor).query_fun
    command_fun = heal_command_fun(ctx)
    deps = [query_fun: query_fun, command_fun: command_fun]

    assert :ok =
             NixSwarm.CLI.run(
               ["cluster", "heal", "db", "--target", Atom.to_string(anchor), "--yes"],
               fn _opts -> :ok end,
               deps
             )

    healed_owner = db_owner(fetch_status(anchor))
    assert healed_owner != owner

    # Restored state is in place on the survivor and the unit reports running.
    assert File.read!(Path.join(ctx.state_dir, "marker.txt")) == "data-42\n"

    assert :ok =
             TestCluster.wait_until(fn ->
               TestCluster.unit_state(ctx.root, healed_owner, "db.service") == "running"
             end)

    assert :ok = TestCluster.wait_until(fn -> owner_serving(anchor) end)

    # The old owner rejoins; deterministic single-writer placement leaves
    # exactly one running copy — never two.
    {_peer, rejoined_node} = TestCluster.restart_peer(cluster, owner)
    assert rejoined_node == owner

    assert :ok =
             TestCluster.wait_until(
               fn ->
                 status = fetch_status(anchor)
                 Enum.sort(status.live_nodes) == @nodes and db_owner(status) != nil
               end,
               20_000
             )

    final_owner = db_owner(fetch_status(anchor))

    assert :ok =
             TestCluster.wait_until(
               fn ->
                 TestCluster.unit_state(ctx.root, final_owner, "db.service") == "running"
               end,
               20_000
             )

    assert :ok =
             TestCluster.wait_until(
               fn ->
                 cluster.nodes
                 |> Enum.reject(&(&1 == final_owner))
                 |> Enum.all?(fn node ->
                   TestCluster.unit_state(ctx.root, node, "db.service") != "running"
                 end)
               end,
               20_000
             )

    # The restored data survived the failover and the final owner serves it.
    assert File.read!(Path.join(ctx.state_dir, "marker.txt")) == "data-42\n"
    assert fetch_status(anchor).live_nodes |> length() == 3
  end
end
