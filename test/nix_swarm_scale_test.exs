defmodule NixSwarmScaleTest do
  # Synthetic large-cluster smoke: 10 real distributed BEAM nodes x 50
  # services (10 replicas each = 500 units) reconcile through a counting
  # executor adapter. Asserts placement completes, the reconcile pass is
  # linear in units (batch status calls are bounded by the service count,
  # not the unit count), and no processes leak. See the v1.0 readiness plan,
  # task H3.
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias NixSwarm.Executor.Counting
  alias NixSwarm.TestCluster

  @node_count 10
  @service_count 50
  @replicas 10
  @unit_count @service_count * @replicas

  defp node_name(i), do: :"node-#{String.pad_leading(Integer.to_string(i), 2, "0")}@127.0.0.1"

  defp node_names, do: Enum.map(1..@node_count, &node_name/1)

  defp service_name(i) do
    "svc-#{String.pad_leading(Integer.to_string(i), 2, "0")}"
  end

  defp services do
    Enum.map(1..@service_count, fn i ->
      %{name: service_name(i), replicas: @replicas}
    end)
  end

  defp build_config(root) do
    %{
      peers: node_names(),
      nodes: Map.new(node_names(), &{&1, %{labels: []}}),
      services: services(),
      runtime: %{
        connect_interval_ms: 100,
        reconcile_interval_ms: 3_600_000,
        autoscale_interval_ms: 3_600_000,
        failure_grace_ms: 5_000,
        recovery_stabilization_ms: 2_000,
        command_timeout_ms: 5_000,
        executor: %{adapter: NixSwarm.Executor.Counting, root: root},
        generation: "scale-test"
      }
    }
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-scale-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    config = build_config(root)

    peers =
      Enum.map(node_names(), fn node ->
        {:ok, peer, node} =
          :peer.start_link(%{name: node, longnames: true, connection: :standard_io})

        :ok = :peer.call(peer, :application, :set_env, [:nix_swarm, :cluster_config, config])

        Enum.each(:code.get_path(), fn path ->
          :peer.call(peer, :code, :add_patha, [path])
        end)

        {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:nix_swarm])
        :ok = :peer.call(peer, NixSwarm.Cluster, :connect_now, [])
        {peer, node}
      end)

    # Full membership before any measurement: reconciles triggered by
    # membership changes during convergence would otherwise pollute counts.
    # Require two consecutive clean samples two seconds apart so late
    # asymmetric connect events have decayed before we measure.
    TestCluster.wait_until(
      fn ->
        membership_full?() and
          (
            Process.sleep(2_000)
            membership_full?()
          )
      end,
      45_000
    )

    on_exit(fn ->
      Enum.each(peers, fn {peer, _node} ->
        try do
          :peer.stop(peer)
        catch
          _, _ -> :ok
        end
      end)

      File.rm_rf!(root)
    end)

    {:ok, root: root, peers: peers}
  end

  test "placement + reconcile are linear in units with no process leaks", context do
    root = context.root

    # Wipe unit state so the measured pass performs a full cold placement.
    wipe_unit_state(root)
    Enum.each(node_names(), &reset_counting(&1, root))

    {pass1_us, _} = timed(&reconcile_all/0)
    assert_snapshot(root, expected_starts: @unit_count, label: "cold pass")

    # A second, identical pass over 500 already-running units must issue no
    # per-unit start/stop/restart operations at all.
    Enum.each(node_names(), &reset_counting(&1, root))
    {pass2_us, _} = timed(&reconcile_all/0)
    assert_snapshot(root, expected_starts: 0, label: "steady pass")

    running = running_unit_count(root)

    assert running == @unit_count,
           "expected all #{@unit_count} units running, found #{running}"

    elapsed_ms = div(pass1_us + pass2_us, 1000)

    IO.puts(
      "scale smoke: #{@node_count} nodes x #{@service_count} services " <>
        "(#{@unit_count} units): cold pass #{div(pass1_us, 1000)} ms, " <>
        "steady pass #{div(pass2_us, 1000)} ms"
    )

    assert elapsed_ms < 30_000, "reconcile passes took #{elapsed_ms} ms (want < 30 s)"

    assert_no_process_leak(context.peers)
  end

  defp membership_full? do
    Enum.all?(node_names(), fn node ->
      case :rpc.call(node, NixSwarm.API, :cluster_members, [], 30_000) do
        %{live_nodes: live, placement_nodes: placed} ->
          Enum.sort(live) == node_names() and Enum.sort(placed) == node_names()

        _ ->
          false
      end
    end)
  end

  defp reconcile_all do
    Enum.each(node_names(), fn node ->
      case :rpc.call(node, NixSwarm.Reconciler, :reconcile_now, [], 60_000) do
        %{results: results} ->
          errors =
            Enum.reject(results, fn
              {_unit, :ok} -> true
              {_unit, {:ok, _}} -> true
              _ -> false
            end)

          unless errors == [] do
            raise "reconcile on #{node} reported #{inspect(errors)}"
          end

        {:badrpc, reason} ->
          raise "reconcile_now on #{node} failed: #{inspect(reason)}"
      end
    end)
  end

  defp reset_counting(node, root) do
    case :rpc.call(node, Counting, :reset, [%{root: root}], 30_000) do
      %{} = _snapshot -> :ok
      {:badrpc, reason} -> raise "counting reset on #{node} failed: #{inspect(reason)}"
    end
  end

  defp assert_snapshot(root, opts) do
    expected_starts = Keyword.fetch!(opts, :expected_starts)
    label = Keyword.fetch!(opts, :label)

    counts =
      Enum.map(node_names(), fn node ->
        case :rpc.call(node, Counting, :snapshot, [%{root: root}], 30_000) do
          %{} = snapshot -> {node, snapshot}
          {:badrpc, reason} -> raise "counting snapshot on #{node} failed: #{inspect(reason)}"
        end
      end)

    total_starts =
      counts
      |> Enum.map(fn {_node, snapshot} -> Map.get(snapshot, :start_unit, 0) end)
      |> Enum.sum()

    assert total_starts == expected_starts,
           "#{label}: expected #{expected_starts} total start_unit calls, got #{total_starts}"

    # Linearity: every node batches unit status in O(services) calls (one
    # cluster-wide batch + one per service), independent of the 500 units.
    Enum.each(counts, fn {node, snapshot} ->
      batches = Map.get(snapshot, :batch_unit_status, 0)

      assert batches == 1 + @service_count,
             "#{label}: #{node} made #{batches} batch calls " <>
               "(want #{1 + @service_count}, linear in services not units)"

      unit_ops =
        Map.take(snapshot, [:start_unit, :stop_unit, :restart_unit])
        |> Map.values()
        |> Enum.sum()

      assert unit_ops <= 2 * @unit_count,
             "#{label}: #{node} issued #{unit_ops} unit operations (suspicious, want linear)"
    end)
  end

  defp wipe_unit_state(root) do
    # Delete only unit state files; leave DETS/log files alone so the open
    # operational-state stores are not disturbed underneath the agents.
    for file <- Path.wildcard(Path.join([root, "**", "*.state"])), do: File.rm(file)
  end

  defp running_unit_count(root) do
    root
    |> Path.join("**/*.state")
    |> Path.wildcard()
    |> Enum.count(fn file ->
      case File.read(file) do
        {:ok, content} -> String.trim(content) == "running"
        _ -> false
      end
    end)
  end

  defp assert_no_process_leak(peers) do
    before_controller = :erlang.system_info(:process_count)

    before_peers =
      Map.new(peers, fn {_peer, node} ->
        {node, :rpc.call(node, :erlang, :system_info, [:process_count], 30_000)}
      end)

    Process.sleep(2_000)

    after_controller = :erlang.system_info(:process_count)
    assert after_controller - before_controller < 400, "controller process leak"

    Enum.each(peers, fn {_peer, node} ->
      after_count = :rpc.call(node, :erlang, :system_info, [:process_count], 30_000)
      delta = after_count - Map.fetch!(before_peers, node)
      assert delta < 400, "process leak on #{node}: #{delta} processes"
    end)
  end

  defp timed(fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    elapsed = System.monotonic_time(:microsecond) - start
    {elapsed, result}
  end
end
