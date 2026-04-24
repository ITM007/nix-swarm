defmodule SwarmTUITest do
  use ExUnit.Case, async: false

  alias ExRatatui
  alias ExRatatui.Event
  alias ExRatatui.Runtime

  test "runtime support check requires an on-disk ex_ratatui native directory" do
    root = Path.join(System.tmp_dir!(), "swarm-tui-runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    assert Swarm.TUI.runtime_supported?(fn :ex_ratatui, "priv/native" -> root end)

    missing_dir = Path.join(root, "missing")
    refute Swarm.TUI.runtime_supported?(fn :ex_ratatui, "priv/native" -> missing_dir end)

    message = Swarm.TUI.runtime_support_error(fn :ex_ratatui, "priv/native" -> missing_dir end)

    assert message =~ "mix run -e 'Swarm.CLI.main(System.argv())' -- --target NODE"
    assert message =~ "swarm --target NODE"
    assert message =~ missing_dir
  end

  test "scene renders the ascii dashboard" do
    terminal = ExRatatui.init_test_terminal(120, 40)

    state = %{
      remote: %{target: "swarm@192.168.1.226"},
      lines: 50,
      refresh_ms: 3_000,
      active_view: :dashboard,
      selected_service: "gitea",
      selected_node: :"node-b@127.0.0.1",
      update_fun: &Swarm.Update.run/2,
      diagnostic: %{
        target: "swarm@192.168.1.226",
        connect_result: true
      },
      overview: %{
        members: %{
          queried_node: :"node-b@127.0.0.1",
          configured_nodes: [:"node-a@127.0.0.1", :"node-b@127.0.0.1", :"node-c@127.0.0.1"],
          live_nodes: [:"node-a@127.0.0.1", :"node-b@127.0.0.1", :"node-c@127.0.0.1"]
        },
        status: %{
          queried_node: :"node-b@127.0.0.1",
          live_nodes: [:"node-a@127.0.0.1", :"node-b@127.0.0.1", :"node-c@127.0.0.1"],
          placements: %{
            "gitea" => [
              %{slot: 0, owner: :"node-c@127.0.0.1", unit: "gitea@0.service"},
              %{slot: 1, owner: :"node-a@127.0.0.1", unit: "gitea@1.service"}
            ],
            "proxy" => [
              %{slot: 0, owner: :"node-c@127.0.0.1", unit: "proxy@0.service"}
            ]
          },
          nodes: [
            {:"node-a@127.0.0.1",
             %{
               services: [
                 %{
                   name: "gitea",
                   local_owned_slots: [1],
                   units: [
                     %{unit: "gitea@0.service", status: :stopped, owner: :"node-c@127.0.0.1"},
                     %{unit: "gitea@1.service", status: :running, owner: :"node-a@127.0.0.1"}
                   ]
                 }
               ]
             }},
            {:"node-b@127.0.0.1",
             %{
               services: [
                 %{
                   name: "gitea",
                   local_owned_slots: [],
                   units: [
                     %{unit: "gitea@0.service", status: :stopped, owner: :"node-c@127.0.0.1"},
                     %{unit: "gitea@1.service", status: :running, owner: :"node-a@127.0.0.1"}
                   ]
                 }
               ]
             }},
            {:"node-c@127.0.0.1",
             %{
               services: [
                 %{
                   name: "gitea",
                   local_owned_slots: [0],
                   units: [
                     %{unit: "gitea@0.service", status: :running, owner: :"node-c@127.0.0.1"},
                     %{unit: "gitea@1.service", status: :stopped, owner: :"node-a@127.0.0.1"}
                   ]
                 },
                 %{
                   name: "proxy",
                   local_owned_slots: [0],
                   units: [
                     %{unit: "proxy@0.service", status: :running, owner: :"node-c@127.0.0.1"}
                   ]
                 }
               ]
             }}
          ]
        }
      },
      service_logs: [],
      cluster_logs: "",
      rollout_confirmation: nil,
      loading: false,
      busy: nil,
      job_ref: nil,
      flash: "refresh complete",
      last_error: nil,
      last_refresh_at: "2026-04-23 21:15:00",
      metrics_history: %{cpu: [10], memory: [20], disk: [30], network: [40]},
      cluster_metrics: %{
        cpu: %{pct: 10, used: 0.8, total: 8, label: "0.8 / 8 cores"},
        memory: %{
          pct: 20,
          used: 8 * 1024 * 1024 * 1024,
          total: 40 * 1024 * 1024 * 1024,
          label: "8 GiB / 40 GiB"
        },
        disk: %{
          pct: 30,
          used: 120 * 1024 * 1024 * 1024,
          total: 400 * 1024 * 1024 * 1024,
          label: "120 GiB / 400 GiB"
        },
        network: %{
          pct: 40,
          used: 40 * 1024 * 1024,
          total: 100 * 1024 * 1024,
          label: "40 MiB/s / 100 MiB/s"
        }
      },
      metrics_sample: nil,
      last_rollout: nil,
      last_snapshot_ms: System.monotonic_time(:millisecond),
      test_pid: nil
    }

    :ok = ExRatatui.draw(terminal, Swarm.TUI.scene(state, 120, 40))
    content = ExRatatui.get_buffer_content(terminal)

    assert content =~ "cpu"
    assert content =~ "memory"
    assert content =~ "disk"
    assert content =~ "network"
  end

  test "dashboard shows stale data indicator and avoids empty metric widgets" do
    terminal = ExRatatui.init_test_terminal(120, 40)

    state = %{
      remote: %{target: "swarm@192.168.1.226"},
      lines: 50,
      refresh_ms: 1_000,
      active_view: :dashboard,
      selected_service: nil,
      selected_node: nil,
      update_fun: &Swarm.Update.run/2,
      diagnostic: %{target: "swarm@192.168.1.226", connect_result: true},
      overview: %{members: %{live_nodes: []}, status: %{placements: %{}, nodes: []}},
      service_logs: [],
      cluster_logs: "",
      log_scroll: 0,
      metrics_history: %{cpu: [], memory: [], disk: [], network: []},
      cluster_metrics: %{
        cpu: %{pct: 0, used: 0.0, total: 0, label: "0 / 0 cores"},
        memory: %{pct: 0, used: 0, total: 0, label: "0 B / 0 B"},
        disk: %{pct: 0, used: 0, total: 0, label: "0 B / 0 B"},
        network: %{pct: 0, used: 0, total: 0, label: "0 B/s / unknown"}
      },
      metrics_sample: nil,
      last_rollout: nil,
      loading: false,
      busy: nil,
      job_ref: nil,
      flash: "refresh complete",
      last_error: nil,
      last_refresh_at: "2026-04-24 11:00:00",
      last_snapshot_ms: System.monotonic_time(:millisecond) - 5_000,
      tick_count: 0,
      rollout_confirmation: nil,
      test_pid: nil
    }

    :ok = ExRatatui.draw(terminal, Swarm.TUI.scene(state, 120, 40))
    content = ExRatatui.get_buffer_content(terminal)

    assert content =~ "stale"
    refute content =~ "no data"
  end

  test "map ascii output is encoded as spans for ratatui" do
    lines =
      Swarm.Ascii.cluster_map(
        %{
          nodes: [
            {:"node-a@127.0.0.1",
             %{
               network_info: %{ips: ["127.0.0.1"], ports: [22, 4370]},
               services: [
                 %{
                   name: "gitea",
                   units: [%{slot: 0, status: :running}]
                 }
               ]
             }}
          ]
        },
        1
      )

    assert Enum.all?(lines, fn line ->
             Enum.all?(line.spans, &match?(%ExRatatui.Text.Span{}, &1))
           end)
  end

  test "map shows full port lists without ellipsis" do
    lines =
      Swarm.Ascii.cluster_map(
        %{
          nodes: [
            {:"node-a@127.0.0.1",
             %{
               network_info: %{ips: ["127.0.0.1"], ports: [22, 80, 443, 3000, 4000, 8080, 8443]},
               services: [
                 %{
                   name: "gitea",
                   ports: [3003],
                   units: [%{slot: 0, status: :running}]
                 }
               ]
             }}
          ]
        },
        1
      )

    rendered =
      lines
      |> Enum.map(fn line -> Enum.map_join(line.spans, "", & &1.content) end)
      |> Enum.join("\n")

    assert rendered =~ "hostname: 127.0.0.1"
    assert rendered =~ "Ports: 22, 80, 443, 3000, 4000"
    assert rendered =~ "        8080, 8443"
    assert rendered =~ "gitea@0 [R] 3003"
    refute rendered =~ "..."
  end

  test "tui loads a remote snapshot and reacts to key events" do
    root = Path.join(System.tmp_dir!(), "swarm-tui-#{System.unique_integer([:positive])}")
    cluster = Swarm.TestCluster.start_three_node_cluster(root)

    on_exit(fn ->
      Swarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    [_node_a, node_b, _node_c] = cluster.nodes

    remote =
      Swarm.Remote.options!(
        target: Atom.to_string(node_b),
        cookie: Atom.to_string(Node.get_cookie())
      )

    pid =
      start_supervised!(
        {Swarm.TUI,
         name: nil, remote: remote, test_mode: {120, 40}, test_pid: self(), refresh_ms: 60_000}
      )

    assert_receive {:tui_update, state, %{snapshot: _snapshot}}, 2_000
    assert state.active_view == :dashboard
    assert state.selected_service == "gitea"
    assert state.selected_node == node_b
    assert Map.has_key?(state.overview.status.placements, "gitea")
    assert state.cluster_metrics.cpu.label =~ "/"
    assert state.cluster_metrics.memory.total > 0
    assert state.cluster_metrics.disk.total > 0
    assert state.service_metrics_by_service["gitea"].cpu.used > 0
    refute state.service_metrics_by_service["gitea"].cpu.label =~ "0 / "
    refute state.service_metrics_by_service["gitea"].disk.label =~ "0 B/s / "
    assert state.service_metrics_by_service["gitea"].network.used > 0

    :ok = Runtime.inject_event(pid, %Event.Key{code: "right", modifiers: [], kind: "press"})
    assert :map == :sys.get_state(pid).user_state.active_view

    :ok = Runtime.inject_event(pid, %Event.Key{code: "tab", modifiers: [], kind: nil})
    assert :machines == :sys.get_state(pid).user_state.active_view
    :ok = Runtime.inject_event(pid, %Event.Key{code: "down", modifiers: [], kind: "press"})

    assert_receive {:tui_update, %{selected_node: selected_node} = node_state,
                    %{snapshot: _snapshot}},
                   2_000

    assert selected_node != node_b
    assert is_binary(node_state.cluster_logs)

    :ok = Runtime.inject_event(pid, %Event.Key{code: "tab", modifiers: [], kind: nil})
    assert :services == :sys.get_state(pid).user_state.active_view
    assert "gitea" == :sys.get_state(pid).user_state.selected_service

    :ok = Runtime.inject_event(pid, %Event.Key{code: "tab", modifiers: [], kind: nil})
    assert :logs == :sys.get_state(pid).user_state.active_view

    :ok = Runtime.inject_event(pid, %Event.Key{code: "left", modifiers: [], kind: "press"})
    assert :services == :sys.get_state(pid).user_state.active_view

    :ok = Runtime.inject_event(pid, %Event.Key{code: "left", modifiers: [], kind: "press"})
    assert :machines == :sys.get_state(pid).user_state.active_view

    :ok = Runtime.inject_event(pid, %Event.Key{code: "left", modifiers: [], kind: "press"})
    assert :map == :sys.get_state(pid).user_state.active_view

    :ok = Runtime.inject_event(pid, %Event.Key{code: "down", modifiers: [], kind: "press"})

    assert_receive {:tui_update, %{selected_service: "proxy"} = updated_state,
                    %{snapshot: _snapshot}},
                   2_000

    assert updated_state.active_view == :map
  end

  test "stale auto refresh results are skipped after user input" do
    ref = make_ref()
    now_ms = System.monotonic_time(:millisecond)

    state = %{
      remote: %{target: "swarm@test"},
      lines: 50,
      refresh_ms: 3_000,
      active_view: :map,
      selected_service: "gitea",
      selected_node: :"node-b@127.0.0.1",
      update_fun: &Swarm.Update.run/2,
      diagnostic: %{target: "swarm@test", connect_result: true},
      overview: %{members: %{live_nodes: []}, status: %{placements: %{}, nodes: []}},
      service_logs: [],
      cluster_logs: "",
      rollout_confirmation: nil,
      loading: true,
      busy: {:refresh, :auto},
      job_ref: ref,
      job_started_at_ms: now_ms - 100,
      pending_refresh: nil,
      flash: nil,
      last_error: nil,
      last_refresh_at: nil,
      metrics_history: %{cpu: [], memory: [], disk: [], network: []},
      cluster_metrics: %{
        cpu: %{pct: 0, used: 0.0, total: 0, label: "0 / 0 cores"},
        memory: %{pct: 0, used: 0, total: 0, label: "0 B / 0 B"},
        disk: %{pct: 0, used: 0, total: 0, label: "0 B / 0 B"},
        network: %{pct: 0, used: 0, total: 0, label: "0 B/s / unknown"}
      },
      metrics_sample: nil,
      last_rollout: nil,
      last_snapshot_ms: nil,
      last_input_at_ms: now_ms,
      test_pid: nil
    }

    payload = %{
      flash: "refresh complete",
      rollout: nil,
      snapshot: %{
        overview: %{members: %{live_nodes: [:changed]}, status: %{placements: %{}, nodes: []}},
        cluster_logs: "changed",
        service_logs: [],
        selected_node: :"other@127.0.0.1",
        selected_service: "proxy",
        captured_at_ms: System.monotonic_time(:millisecond)
      }
    }

    assert {:noreply, updated_state} =
             Swarm.TUI.handle_info({:job_result, ref, {:ok, payload}}, state)

    assert updated_state.active_view == :map
    assert updated_state.cluster_logs == ""
    assert updated_state.pending_refresh == :auto
  end

  test "auto refresh is deferred while a prompt is open" do
    state = %{
      refresh_ms: 3_000,
      prompt: %{kind: :generic, title: "prompt", label: "value", value: ""},
      rollout_confirmation: nil,
      pending_refresh: nil,
      job_ref: nil
    }

    assert {:noreply, updated_state, [render?: false]} = Swarm.TUI.handle_info(:refresh, state)
    assert updated_state.pending_refresh == :auto
  end

  test "logs scene renders aggregated cluster logs" do
    state = %{
      remote: %{target: "swarm@test"},
      active_view: :logs,
      cluster_event_logs: "== node-a ==\nservice restarted",
      loading: false,
      busy: nil,
      overview: nil,
      diagnostic: nil,
      last_refresh_at: nil,
      last_snapshot_ms: nil,
      last_error: nil,
      flash: "ready",
      tick_count: 0,
      content_scroll_x: 0,
      content_scroll_y: 0,
      prompt: nil,
      rollout_confirmation: nil
    }

    terminal = ExRatatui.init_test_terminal(100, 20)
    :ok = ExRatatui.draw(terminal, Swarm.TUI.scene(state, 100, 20))
    content = ExRatatui.get_buffer_content(terminal)

    assert content =~ "cluster logs"
    assert content =~ "service restarted"
  end

  test "tui update hotkey refreshes the cluster after a rollout" do
    root = Path.join(System.tmp_dir!(), "swarm-tui-update-#{System.unique_integer([:positive])}")
    cluster = Swarm.TestCluster.start_three_node_cluster(root)

    on_exit(fn ->
      Swarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    [_node_a, node_b, _node_c] = cluster.nodes

    remote =
      Swarm.Remote.options!(
        target: Atom.to_string(node_b),
        cookie: Atom.to_string(Node.get_cookie())
      )

    test_pid = self()

    update_fun = fn deploy_opts, _remote ->
      send(test_pid, {:rollout_hosts, Keyword.get(deploy_opts, :hosts, [])})

      %{
        after_versions: %{
          Atom.to_string(node_b) => "v0.1.0-test-rollout"
        },
        version_changed?: true,
        completed_at: "2026-04-24 11:45:00"
      }
    end

    pid =
      start_supervised!(
        {Swarm.TUI,
         name: nil,
         remote: remote,
         test_mode: {120, 40},
         test_pid: self(),
         refresh_ms: 60_000,
         update_fun: update_fun}
      )

    assert_receive {:tui_update, _state, %{snapshot: _snapshot}}, 2_000

    :ok = Runtime.inject_event(pid, %Event.Key{code: "u", modifiers: [], kind: "press"})
    refute_receive {:rollout_hosts, _hosts}, 200
    assert :sys.get_state(pid).user_state.rollout_confirmation != nil

    :ok = Runtime.inject_event(pid, %Event.Key{code: "enter", modifiers: [], kind: "press"})

    assert_receive {:tui_update, updated_state, %{snapshot: _snapshot}}, 2_000
    assert_receive {:rollout_hosts, ["root@node-a", "root@node-b", "root@node-c"]}, 2_000
    assert updated_state.flash =~ "cluster updated"
    assert updated_state.last_error == nil
    assert updated_state.last_rollout.version_changed? == true
    assert updated_state.last_rollout.completed_at == "2026-04-24 11:45:00"
  end

  test "tui restart and reconcile hotkeys control the cluster" do
    root = Path.join(System.tmp_dir!(), "swarm-tui-control-#{System.unique_integer([:positive])}")
    cluster = Swarm.TestCluster.start_three_node_cluster(root)

    on_exit(fn ->
      Swarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    [_node_a, node_b, _node_c] = cluster.nodes

    remote =
      Swarm.Remote.options!(
        target: Atom.to_string(node_b),
        cookie: Atom.to_string(Node.get_cookie())
      )

    pid =
      start_supervised!(
        {Swarm.TUI,
         name: nil, remote: remote, test_mode: {120, 40}, test_pid: self(), refresh_ms: 60_000}
      )

    assert_receive {:tui_update, _state, %{snapshot: _snapshot}}, 2_000

    :ok = Runtime.inject_event(pid, %Event.Key{code: "x", modifiers: [], kind: "press"})

    assert_receive {:tui_update, restart_state, %{snapshot: _snapshot}}, 2_000
    assert restart_state.flash =~ "restart requested for gitea"
    assert restart_state.last_error == nil

    :ok = Runtime.inject_event(pid, %Event.Key{code: "c", modifiers: [], kind: "press"})

    assert_receive {:tui_update, reconcile_state, %{snapshot: _snapshot}}, 2_000
    assert reconcile_state.flash =~ "reconcile completed on 3 live node(s)"
    assert reconcile_state.last_error == nil
  end

  test "tui dry-run hotkey stores apply preview output" do
    root = Path.join(System.tmp_dir!(), "swarm-tui-apply-#{System.unique_integer([:positive])}")
    cluster = Swarm.TestCluster.start_three_node_cluster(root)

    on_exit(fn ->
      Swarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    [_node_a, node_b, _node_c] = cluster.nodes

    remote =
      Swarm.Remote.options!(
        target: Atom.to_string(node_b),
        cookie: Atom.to_string(Node.get_cookie())
      )

    deploy_fun = fn opts ->
      %{
        dry_run: Keyword.get(opts, :dry_run, false),
        validation: %{
          machine_files: [Path.join(root, "machines/node-a.nix")],
          commands: ["validate"]
        },
        results: [
          %{
            host: "root@node-a",
            sync_command: "sync-command",
            rebuild_command: "rebuild-command"
          }
        ]
      }
    end

    pid =
      start_supervised!(
        {Swarm.TUI,
         name: nil,
         remote: remote,
         test_mode: {120, 40},
         test_pid: self(),
         refresh_ms: 60_000,
         deploy_fun: deploy_fun,
         config_paths: Swarm.ConfigFiles.defaults(root)}
      )

    assert_receive {:tui_update, _state, %{snapshot: _snapshot}}, 2_000

    :ok = Runtime.inject_event(pid, %Event.Key{code: "y", modifiers: [], kind: "press"})

    assert_receive {:tui_update, updated_state, %{snapshot: _snapshot}}, 2_000
    assert updated_state.flash == "dry-run complete"
    assert updated_state.apply_result.dry_run
    assert hd(updated_state.apply_result.results).host == "root@node-a"
  end

  test "shift navigation scrolls long content panes" do
    state = %{
      content_scroll_x: 0,
      content_scroll_y: 0,
      log_scroll: 0,
      prompt: nil,
      rollout_confirmation: nil,
      last_input_at_ms: nil
    }

    assert {:noreply, after_down} =
             Swarm.TUI.handle_event(
               %Event.Key{code: "j", modifiers: ["shift"], kind: "press"},
               state
             )

    assert after_down.content_scroll_y == 1
    assert after_down.log_scroll == 1

    assert {:noreply, after_right} =
             Swarm.TUI.handle_event(
               %Event.Key{code: "l", modifiers: ["shift"], kind: "press"},
               after_down
             )

    assert after_right.content_scroll_x == 2
  end
end
