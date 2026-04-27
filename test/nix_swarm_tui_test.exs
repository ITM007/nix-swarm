defmodule NixSwarmTUITest do
  use ExUnit.Case, async: false

  alias ExRatatui
  alias ExRatatui.Event
  alias ExRatatui.Runtime

  test "runtime support check requires an on-disk ex_ratatui native directory" do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-tui-runtime-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    assert NixSwarm.TUI.runtime_supported?(fn :ex_ratatui, "priv/native" -> root end)

    missing_dir = Path.join(root, "missing")
    refute NixSwarm.TUI.runtime_supported?(fn :ex_ratatui, "priv/native" -> missing_dir end)

    message = NixSwarm.TUI.runtime_support_error(fn :ex_ratatui, "priv/native" -> missing_dir end)

    assert message =~ "mix run -e 'NixSwarm.CLI.main(System.argv())' -- --target NODE"
    assert message =~ "nix-swarm --target NODE"
    assert message =~ missing_dir
  end

  test "scene renders the ascii dashboard" do
    terminal = ExRatatui.init_test_terminal(120, 40)

    state = %{
      remote: %{target: "nix-swarm@example-node-a.local"},
      lines: 50,
      refresh_ms: 3_000,
      active_view: :dashboard,
      selected_service: "gitea",
      selected_node: :"node-b@127.0.0.1",
      update_fun: &NixSwarm.Update.run/2,
      diagnostic: %{
        target: "nix-swarm@example-node-a.local",
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
                   desired_state: :running,
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

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 120, 40))
    content = ExRatatui.get_buffer_content(terminal)

    assert content =~ "cpu"
    assert content =~ "memory"
    assert content =~ "disk"
    assert content =~ "network"
  end

  test "dashboard shows stale data indicator and avoids empty metric widgets" do
    terminal = ExRatatui.init_test_terminal(120, 40)

    state = %{
      remote: %{target: "nix-swarm@example-node-a.local"},
      lines: 50,
      refresh_ms: 1_000,
      active_view: :dashboard,
      selected_service: nil,
      selected_node: nil,
      update_fun: &NixSwarm.Update.run/2,
      diagnostic: %{target: "nix-swarm@example-node-a.local", connect_result: true},
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

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 120, 40))
    content = ExRatatui.get_buffer_content(terminal)

    assert content =~ "stale"
    refute content =~ "no data"
  end

  test "map ascii output is encoded as spans for ratatui" do
    lines =
      NixSwarm.Ascii.cluster_map(
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
      NixSwarm.Ascii.cluster_map(
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

  test "map hides stopped services and shows machine errors" do
    lines =
      NixSwarm.Ascii.cluster_map(
        %{
          nodes: [
            {:"nix-swarm@node-a.lan",
             %{
               network_info: %{ips: ["10.0.0.1"], ports: [22, 443]},
               services: [
                 %{
                   name: "gitea",
                   ports: [3000],
                   units: [
                     %{slot: 0, owner: :"nix-swarm@node-a.lan", status: :stopped},
                     %{slot: 1, owner: :"nix-swarm@node-a.lan", status: :running}
                   ]
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

    assert rendered =~ "gitea@1 [R] 3000"
    refute rendered =~ "gitea@0 [S]"
    assert rendered =~ "Errors:"
    assert rendered =~ "gitea@0 stopped"
  end

  test "dashboard and services views render service tables with hostname owners" do
    dashboard_terminal = ExRatatui.init_test_terminal(140, 40)
    services_terminal = ExRatatui.init_test_terminal(140, 40)

    dashboard_state = sample_tui_state(:dashboard)
    services_state = sample_tui_state(:services)

    :ok = ExRatatui.draw(dashboard_terminal, NixSwarm.TUI.scene(dashboard_state, 140, 40))
    :ok = ExRatatui.draw(services_terminal, NixSwarm.TUI.scene(services_state, 140, 40))

    dashboard_content = ExRatatui.get_buffer_content(dashboard_terminal)
    services_content = ExRatatui.get_buffer_content(services_terminal)

    assert dashboard_content =~ "name"
    assert dashboard_content =~ "replicas"
    assert dashboard_content =~ "owners"
    assert dashboard_content =~ "node-a.lan, node-b.lan"

    assert services_content =~ "name"
    assert services_content =~ "replicas"
    assert services_content =~ "owners"
    assert services_content =~ "node-b.lan"
  end

  test "machines view renders the machine table columns" do
    terminal = ExRatatui.init_test_terminal(180, 40)
    state = sample_tui_state(:machines)

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 180, 40))
    content = ExRatatui.get_buffer_content(terminal)

    assert content =~ "host name"
    assert content =~ "node name"
    assert content =~ "status"
    assert content =~ "version"
    assert content =~ "node-a.lan"
    assert content =~ "nix-swarm@node-a.lan"
    assert content =~ "v1.0.0"
  end

  test "service and machine views render stopped and restarting states" do
    services_terminal = ExRatatui.init_test_terminal(180, 40)
    machines_terminal = ExRatatui.init_test_terminal(180, 40)

    services_state =
      sample_tui_state(:services)
      |> Map.put(:selected_service, "proxy")
      |> put_in(
        [
          :overview,
          :status,
          :nodes,
          Access.at(1),
          Access.elem(1),
          :services,
          Access.at(1),
          :desired_state
        ],
        :stopped
      )
      |> put_in(
        [
          :overview,
          :status,
          :nodes,
          Access.at(1),
          Access.elem(1),
          :services,
          Access.at(1),
          :units,
          Access.at(0),
          :status
        ],
        :stopped
      )

    machines_state =
      sample_tui_state(:machines)
      |> Map.put(:pending_machine_actions, %{
        :"nix-swarm@node-a.lan" => %{
          action: :restart,
          started_at_ms: System.monotonic_time(:millisecond)
        }
      })

    :ok = ExRatatui.draw(services_terminal, NixSwarm.TUI.scene(services_state, 180, 40))
    :ok = ExRatatui.draw(machines_terminal, NixSwarm.TUI.scene(machines_state, 180, 40))

    services_content = ExRatatui.get_buffer_content(services_terminal)
    machines_content = ExRatatui.get_buffer_content(machines_terminal)

    assert services_content =~ "status: stopped"
    assert machines_content =~ "restarting"
  end

  test "pane titles show selection, summary, and log key hints" do
    terminal = ExRatatui.init_test_terminal(220, 40)
    state = sample_tui_state(:services)

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 220, 40))
    content = ExRatatui.get_buffer_content(terminal)

    assert content =~ "services [arrows/j/k | o name↑]"
    assert content =~ "service summary [arrows/hjkl]"
    assert content =~ "service logs [arrows/hjkl]"
  end

  test "scene renders the issues strip and log context header" do
    terminal = ExRatatui.init_test_terminal(180, 28)
    state = sample_tui_state(:services)

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 180, 28))
    content = ExRatatui.get_buffer_content(terminal)

    assert content =~ "machines with issues: 0"
    assert content =~ "services with issues:"
    assert content =~ "log context"
    assert content =~ "service: gitea"
    assert content =~ "tail: on"
  end

  test "help overlay renders current-view shortcuts" do
    terminal = ExRatatui.init_test_terminal(120, 28)
    state = sample_tui_state(:logs) |> Map.put(:help_overlay, true)

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 120, 28))
    content = ExRatatui.get_buffer_content(terminal)

    assert content =~ "Logs"
    assert content =~ "shift+tab"
    assert content =~ "mouse click"
    assert content =~ "1-4 / f"
    assert content =~ "C / E"
  end

  test "tui loads a remote snapshot and reacts to key events" do
    root = Path.join(System.tmp_dir!(), "nix-swarm-tui-#{System.unique_integer([:positive])}")
    cluster = NixSwarm.TestCluster.start_three_node_cluster(root)

    on_exit(fn ->
      NixSwarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    [_node_a, node_b, _node_c] = cluster.nodes

    remote =
      NixSwarm.Remote.options!(
        target: Atom.to_string(node_b),
        cookie: Atom.to_string(Node.get_cookie())
      )

    pid =
      start_supervised!(
        {NixSwarm.TUI,
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
    assert state.service_metrics_by_service["gitea"].cpu.used >= 0
    refute state.service_metrics_by_service["gitea"].cpu.label =~ "0 / "
    refute state.service_metrics_by_service["gitea"].disk.label =~ "0 B/s / "
    assert state.service_metrics_by_service["gitea"].network.used > 0

    :ok = Runtime.inject_event(pid, %Event.Key{code: "tab", modifiers: [], kind: "press"})
    assert :map == :sys.get_state(pid).user_state.active_view
    assert :map_canvas == :sys.get_state(pid).user_state.focused_container

    :ok = Runtime.inject_event(pid, %Event.Key{code: "down", modifiers: [], kind: "press"})

    assert_receive {:tui_update, %{selected_service: "proxy"} = updated_map_state,
                    %{snapshot: _snapshot}},
                   2_000

    assert updated_map_state.active_view == :map

    :ok = Runtime.inject_event(pid, %Event.Key{code: "tab", modifiers: [], kind: "press"})
    assert :machines == :sys.get_state(pid).user_state.active_view
    assert :machines_table == :sys.get_state(pid).user_state.focused_container
    :ok = Runtime.inject_event(pid, %Event.Key{code: "down", modifiers: [], kind: "press"})

    assert_receive {:tui_update, %{selected_node: selected_node} = node_state,
                    %{snapshot: _snapshot}},
                   2_000

    assert selected_node != node_b
    assert is_binary(node_state.cluster_logs)

    :ok = Runtime.inject_event(pid, %Event.Key{code: "back_tab", modifiers: [], kind: "press"})
    assert :machines_summary == :sys.get_state(pid).user_state.focused_container

    :ok = Runtime.inject_event(pid, %Event.Key{code: "tab", modifiers: [], kind: "press"})
    assert :services == :sys.get_state(pid).user_state.active_view
    assert :services_table == :sys.get_state(pid).user_state.focused_container
    assert "proxy" == :sys.get_state(pid).user_state.selected_service

    :ok = Runtime.inject_event(pid, %Event.Key{code: "back_tab", modifiers: [], kind: "press"})
    assert :services_summary == :sys.get_state(pid).user_state.focused_container

    :ok = Runtime.inject_event(pid, %Event.Key{code: "tab", modifiers: [], kind: "press"})
    assert :logs == :sys.get_state(pid).user_state.active_view
    assert :logs_content == :sys.get_state(pid).user_state.focused_container

    :ok = Runtime.inject_event(pid, %Event.Key{code: "back_tab", modifiers: [], kind: "press"})
    assert :logs_filter == :sys.get_state(pid).user_state.focused_container
  end

  test "stale auto refresh results are skipped after user input" do
    ref = make_ref()
    now_ms = System.monotonic_time(:millisecond)

    state = %{
      remote: %{target: "nix-swarm@test"},
      lines: 50,
      refresh_ms: 3_000,
      active_view: :map,
      selected_service: "gitea",
      selected_node: :"node-b@127.0.0.1",
      update_fun: &NixSwarm.Update.run/2,
      diagnostic: %{target: "nix-swarm@test", connect_result: true},
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
             NixSwarm.TUI.handle_info({:job_result, ref, {:ok, payload}}, state)

    assert updated_state.active_view == :map
    assert updated_state.cluster_logs == ""
    assert updated_state.pending_refresh == :auto
  end

  test "update requests are queued while a refresh job is running" do
    ref = make_ref()

    state =
      sample_tui_state(:services)
      |> Map.merge(%{
        loading: true,
        busy: {:refresh, :auto},
        job_ref: ref,
        job_started_at_ms: System.monotonic_time(:millisecond) - 100,
        pending_refresh: nil
      })

    assert {:noreply, queued_state} =
             NixSwarm.TUI.handle_event(%Event.Key{code: "u", modifiers: [], kind: "press"}, state)

    assert queued_state.pending_operator_action == :update
    assert queued_state.rollout_confirmation == nil

    payload = %{
      flash: "refresh complete",
      snapshot: %{
        diagnostic: state.diagnostic,
        overview: state.overview,
        selected_service: state.selected_service,
        selected_node: state.selected_node,
        service_logs: state.service_logs,
        cluster_logs: state.cluster_logs,
        cluster_event_logs: state.cluster_event_logs,
        last_refresh_at: "2026-04-26 14:45:00",
        captured_at_ms: System.monotonic_time(:millisecond)
      }
    }

    assert {:noreply, updated_state} =
             NixSwarm.TUI.handle_info({:job_result, ref, {:ok, payload}}, queued_state)

    assert updated_state.pending_operator_action == nil
    assert updated_state.rollout_confirmation != nil
    assert updated_state.flash =~ "rollout ready"
  end

  test "auto refresh is deferred while a prompt is open" do
    state = %{
      refresh_ms: 3_000,
      prompt: %{kind: :generic, title: "prompt", label: "value", value: ""},
      rollout_confirmation: nil,
      pending_refresh: nil,
      job_ref: nil
    }

    assert {:noreply, updated_state, [render?: false]} = NixSwarm.TUI.handle_info(:refresh, state)
    assert updated_state.pending_refresh == :auto
  end

  test "logs scene renders aggregated cluster logs" do
    state = %{
      remote: %{target: "nix-swarm@test"},
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
    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 100, 20))
    content = ExRatatui.get_buffer_content(terminal)

    assert content =~ "cluster logs"
    assert content =~ "service restarted"
  end

  test "scene renders multiline footer errors without crashing" do
    terminal = ExRatatui.init_test_terminal(160, 24)

    state =
      sample_tui_state(:services)
      |> Map.put(
        :last_error,
        "update failed\nExRatatui render error: Span content cannot contain newlines"
      )
      |> Map.put(:flash, "last action failed")

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 160, 24))
    content = ExRatatui.get_buffer_content(terminal)

    assert content =~
             "status: update failed ExRatatui render error: Span content cannot contain newlines"
  end

  test "machine log rendering filters benign epmd noise" do
    terminal = ExRatatui.init_test_terminal(180, 24)

    state =
      sample_tui_state(:machines)
      |> Map.put(
        :cluster_logs,
        Enum.join(
          [
            "Apr 26 10:44:59 example-control epmd[529625]: epmd: got partial packet only on file descriptor 6 (0)",
            "Apr 27 03:50:40 example-control nix-swarmd[2209676]: 03:50:40.303 [notice]     :alarm_handler: {:set, {:system_memory_high_watermark, []}}",
            "Apr 27 03:56:40 example-control nix-swarmd[2209676]: 03:56:40.313 [notice]     :alarm_handler: {:clear, :system_memory_high_watermark}",
            "Apr 26 18:49:59 example-control nix-swarmd[1948512]: 18:49:59.187 [notice] SIGTERM received - shutting down",
            "Apr 26 18:49:59 example-control nix-swarmd[1948512]: State: [data: [{~c\"Timeout\", 60000}], items: {~c\"Memory Usage\", [{~c\"Allocated\", 25275826176}]}]",
            "Apr 26 10:45:00 example-control nix-swarmd[123]: service restarted"
          ],
          "\n"
        )
      )

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 180, 24))
    content = ExRatatui.get_buffer_content(terminal)

    refute content =~ "epmd: got partial packet only"
    refute content =~ "system_memory_high_watermark"
    refute content =~ "SIGTERM received - shutting down"
    refute content =~ "State: [data:"
    assert content =~ "service restarted"
  end

  test "dashboard footer only advertises cluster-level actions" do
    terminal = ExRatatui.init_test_terminal(220, 40)
    state = sample_tui_state(:dashboard)

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 220, 40))
    content = ExRatatui.get_buffer_content(terminal)

    assert content =~ "c reconcile"
    assert content =~ "u update"
    assert content =~ "P/y apply/dry-run"
    assert content =~ "j/k service | o sort | ? help"
    refute content =~ "mouse click/wheel"
    refute content =~ "b start"
    refute content =~ "x restart"
  end

  test "services footer omits mouse click and wheel hints" do
    terminal = ExRatatui.init_test_terminal(220, 40)
    state = sample_tui_state(:services)

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 220, 40))
    content = ExRatatui.get_buffer_content(terminal)

    refute content =~ "mouse click/wheel"
    assert content =~ "b start | z stop | x restart"
  end

  test "logs page strips benign restart and partition warnings from issue counts" do
    terminal = ExRatatui.init_test_terminal(220, 28)

    state =
      sample_tui_state(:logs)
      |> Map.put(
        :cluster_event_logs,
        Enum.join(
          [
            "== nix-swarm@example-control.local ==",
            "Apr 26 18:49:59 example-control nix-swarmd[1948512]: 18:49:59.187 [notice] SIGTERM received - shutting down",
            "Apr 26 18:49:59 example-control nix-swarmd[1948512]: State: [data: [{~c\"Timeout\", 60000}], items: {~c\"Memory Usage\", [{~c\"Allocated\", 25275826176}]}]",
            "",
            "== nix-swarm@example-node-b.local ==",
            "Apr 26 01:25:09 example-node-b nix-swarmd[194114]: 01:25:09.566 [warning] 'global' at node :\"nix-swarm@example-node-b.local\" requested disconnect from node :\"nix-swarm@example-control.local\" in order to prevent overlapping partitions",
            "",
            "== nix-swarm@example-node-a.local ==",
            "Apr 26 01:25:09 example-node-a nix-swarmd[188883]: 01:25:09.565 [warning] 'global' at :\"nix-swarm@example-node-a.local\" failed to connect to :\"nix-swarm@example-control.local\"",
            "Apr 26 01:25:10 example-node-a nix-swarmd[188883]: 01:25:10.565 [warning] service still unhealthy"
          ],
          "\n"
        )
      )

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 220, 28))
    content = ExRatatui.get_buffer_content(terminal)

    refute content =~ "SIGTERM received - shutting down"
    refute content =~ "State: [data:"
    refute content =~ "requested disconnect from node"
    refute content =~ "failed to connect to"
    assert content =~ "service still unhealthy"
    assert content =~ "warning/error log lines: 1"
  end

  test "logs page filter bar switches between all, errors, machine, and service views" do
    terminal = ExRatatui.init_test_terminal(180, 24)
    state = sample_tui_state(:logs)

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 180, 24))
    all_content = ExRatatui.get_buffer_content(terminal)

    assert all_content =~ "log filter [1-4/f]"
    assert all_content =~ "cluster healthy"
    assert all_content =~ "01:01:02 error machine issue"

    assert {:noreply, errors_state} =
             NixSwarm.TUI.handle_event(%Event.Key{code: "2", modifiers: [], kind: "press"}, state)

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(errors_state, 180, 24))
    errors_content = ExRatatui.get_buffer_content(terminal)

    refute errors_content =~ "cluster healthy"
    assert errors_content =~ "error machine issue"
    assert errors_content =~ "warning service flap"

    assert {:noreply, machine_state} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "3", modifiers: [], kind: "press"},
               errors_state
             )

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(machine_state, 180, 24))
    machine_content = ExRatatui.get_buffer_content(terminal)

    assert machine_content =~ "selected machine log entry"

    assert {:noreply, service_state} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "4", modifiers: [], kind: "press"},
               machine_state
             )

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(service_state, 180, 24))
    service_content = ExRatatui.get_buffer_content(terminal)

    assert service_content =~ "selected service log entry"
  end

  test "tui update hotkey refreshes the cluster after a rollout" do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-tui-update-#{System.unique_integer([:positive])}")

    cluster = NixSwarm.TestCluster.start_three_node_cluster(root)

    on_exit(fn ->
      NixSwarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    [_node_a, node_b, _node_c] = cluster.nodes

    remote =
      NixSwarm.Remote.options!(
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
        {NixSwarm.TUI,
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

  test "machines view update confirmation can switch between selected machine and cluster scopes" do
    state = sample_tui_state(:machines)

    assert {:noreply, machine_scope_state} =
             NixSwarm.TUI.handle_event(%Event.Key{code: "u", modifiers: [], kind: "press"}, state)

    assert machine_scope_state.rollout_confirmation.scope == :selected_machine
    assert machine_scope_state.rollout_confirmation.target_hosts == ["root@node-a"]
    assert machine_scope_state.rollout_confirmation.target_nodes == ["nix-swarm@node-a.lan"]

    assert {:noreply, cluster_scope_state} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "c", modifiers: [], kind: "press"},
               machine_scope_state
             )

    assert cluster_scope_state.rollout_confirmation.scope == :cluster
    assert cluster_scope_state.rollout_confirmation.target_hosts == ["root@node-a", "root@node-b"]

    assert cluster_scope_state.rollout_confirmation.target_nodes == [
             "nix-swarm@node-a.lan",
             "nix-swarm@node-b.lan"
           ]

    assert {:noreply, switched_back_state} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "m", modifiers: [], kind: "press"},
               cluster_scope_state
             )

    assert switched_back_state.rollout_confirmation.scope == :selected_machine
    assert switched_back_state.rollout_confirmation.target_hosts == ["root@node-a"]
  end

  test "tui service hotkeys start, stop, restart, and reconcile the cluster" do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-tui-control-#{System.unique_integer([:positive])}")

    cluster = NixSwarm.TestCluster.start_three_node_cluster(root)

    on_exit(fn ->
      NixSwarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    [_node_a, node_b, _node_c] = cluster.nodes

    remote =
      NixSwarm.Remote.options!(
        target: Atom.to_string(node_b),
        cookie: Atom.to_string(Node.get_cookie())
      )

    pid =
      start_supervised!(
        {NixSwarm.TUI,
         name: nil, remote: remote, test_mode: {120, 40}, test_pid: self(), refresh_ms: 60_000}
      )

    assert_receive {:tui_update, _state, %{snapshot: _snapshot}}, 2_000

    :ok = Runtime.inject_event(pid, %Event.Key{code: "z", modifiers: [], kind: "press"})

    assert_receive {:tui_update, stop_state, %{snapshot: _snapshot}}, 2_000
    assert stop_state.flash =~ "stop requested for gitea"
    assert stop_state.last_error == nil

    assert :ok ==
             NixSwarm.TestCluster.wait_until(fn ->
               service_fully_stopped?(cluster, "gitea")
             end)

    :ok = Runtime.inject_event(pid, %Event.Key{code: "b", modifiers: [], kind: "press"})

    assert_receive {:tui_update, start_state, %{snapshot: _snapshot}}, 2_000
    assert start_state.flash =~ "start requested for gitea"
    assert start_state.last_error == nil

    assert :ok ==
             NixSwarm.TestCluster.wait_until(fn ->
               service_placement_converged?(cluster, "gitea")
             end)

    :ok = Runtime.inject_event(pid, %Event.Key{code: "x", modifiers: [], kind: "press"})

    assert_receive {:tui_update, restart_state, %{snapshot: _snapshot}}, 2_000
    assert restart_state.flash =~ "restart requested for gitea"
    assert restart_state.last_error == nil

    :ok = Runtime.inject_event(pid, %Event.Key{code: "c", modifiers: [], kind: "press"})

    assert_receive {:tui_update, reconcile_state, %{snapshot: _snapshot}}, 2_000
    assert reconcile_state.flash =~ "reconcile completed on 3 live node(s)"
    assert reconcile_state.last_error == nil
  end

  test "tui machine power hotkeys confirm and dispatch actions" do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-tui-machine-#{System.unique_integer([:positive])}")

    cluster = NixSwarm.TestCluster.start_three_node_cluster(root)

    on_exit(fn ->
      NixSwarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    [node_a, node_b, _node_c] = cluster.nodes

    remote =
      NixSwarm.Remote.options!(
        target: Atom.to_string(node_b),
        cookie: Atom.to_string(Node.get_cookie())
      )

    pid =
      start_supervised!(
        {NixSwarm.TUI,
         name: nil,
         remote: remote,
         test_mode: {120, 40},
         test_pid: self(),
         refresh_ms: 60_000,
         resume_state: %{active_view: :machines, selected_node: node_a}}
      )

    assert_receive {:tui_update, _state, %{snapshot: _snapshot}}, 2_000

    :ok = Runtime.inject_event(pid, %Event.Key{code: "R", modifiers: [], kind: "press"})
    Process.sleep(25)

    assert %{action: :restart, node: ^node_a} = :sys.get_state(pid).user_state.action_confirmation

    :ok = Runtime.inject_event(pid, %Event.Key{code: "enter", modifiers: [], kind: "press"})

    assert_receive {:tui_update, restart_state, %{snapshot: _snapshot}}, 2_000
    assert restart_state.flash =~ "restart requested for node-a"
    assert restart_state.last_error == nil

    assert :ok ==
             NixSwarm.TestCluster.wait_until(fn ->
               cluster.root
               |> NixSwarm.TestCluster.machine_actions(node_a)
               |> Enum.any?(&String.contains?(&1, "restart"))
             end)

    :ok = Runtime.inject_event(pid, %Event.Key{code: "Z", modifiers: [], kind: "press"})
    Process.sleep(25)

    assert %{action: :shutdown, node: ^node_a} =
             :sys.get_state(pid).user_state.action_confirmation

    :ok = Runtime.inject_event(pid, %Event.Key{code: "enter", modifiers: [], kind: "press"})

    assert_receive {:tui_update, shutdown_state, %{snapshot: _snapshot}}, 2_000
    assert shutdown_state.flash =~ "shutdown requested for node-a"
    assert shutdown_state.last_error == nil

    assert :ok ==
             NixSwarm.TestCluster.wait_until(fn ->
               cluster.root
               |> NixSwarm.TestCluster.machine_actions(node_a)
               |> Enum.any?(&String.contains?(&1, "shutdown"))
             end)
  end

  test "tui dry-run hotkey stores apply preview output" do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-tui-apply-#{System.unique_integer([:positive])}")

    cluster = NixSwarm.TestCluster.start_three_node_cluster(root)

    on_exit(fn ->
      NixSwarm.TestCluster.stop_cluster(cluster)
      File.rm_rf!(root)
    end)

    [_node_a, node_b, _node_c] = cluster.nodes

    remote =
      NixSwarm.Remote.options!(
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
        {NixSwarm.TUI,
         name: nil,
         remote: remote,
         test_mode: {120, 40},
         test_pid: self(),
         refresh_ms: 60_000,
         deploy_fun: deploy_fun,
         config_paths: NixSwarm.ConfigFiles.defaults(root)}
      )

    assert_receive {:tui_update, _state, %{snapshot: _snapshot}}, 2_000

    :ok = Runtime.inject_event(pid, %Event.Key{code: "y", modifiers: [], kind: "press"})

    assert_receive {:tui_update, updated_state, %{snapshot: _snapshot}}, 2_000
    assert updated_state.flash == "dry-run complete"
    assert updated_state.apply_result.dry_run
    assert hd(updated_state.apply_result.results).host == "root@node-a"
  end

  test "shift tab cycles focus and routes movement to the focused pane" do
    state =
      sample_tui_state(:services)
      |> Map.merge(%{
        summary_scroll_x: 0,
        summary_scroll_y: 0,
        content_scroll_x: 0,
        content_scroll_y: 0,
        log_scroll: 0
      })

    assert {:noreply, summary_focus} =
             NixSwarm.TUI.handle_event(%Event.Key{code: "back_tab", kind: "press"}, state)

    assert summary_focus.focused_container == :services_summary

    assert {:noreply, after_summary_down} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "down", modifiers: [], kind: "press"},
               summary_focus
             )

    assert after_summary_down.summary_scroll_y == 1
    assert after_summary_down.content_scroll_y == 0

    assert {:noreply, logs_focus} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "back_tab", kind: "press"},
               after_summary_down
             )

    assert logs_focus.focused_container == :services_logs

    assert {:noreply, after_logs_down} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "down", modifiers: [], kind: "press"},
               logs_focus
             )

    assert after_logs_down.summary_scroll_y == 1
    assert after_logs_down.content_scroll_y == 1
    assert after_logs_down.log_scroll == 1

    assert {:noreply, table_focus} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "back_tab", kind: "press"},
               after_logs_down
             )

    assert table_focus.focused_container == :services_table

    assert {:noreply, after_table_down} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "down", modifiers: [], kind: "press"},
               table_focus
             )

    assert after_table_down.selected_service == "proxy"
  end

  test "vim motions use hjkl navigation" do
    state = sample_tui_state(:services)

    assert {:noreply, after_j} =
             NixSwarm.TUI.handle_event(%Event.Key{code: "j", modifiers: [], kind: "press"}, state)

    assert after_j.selected_service == "proxy"

    assert {:noreply, after_k} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "k", modifiers: [], kind: "press"},
               after_j
             )

    assert after_k.selected_service == "gitea"

    assert {:noreply, summary_focus} =
             NixSwarm.TUI.handle_event(%Event.Key{code: "back_tab", kind: "press"}, state)

    assert {:noreply, after_l} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "l", modifiers: [], kind: "press"},
               summary_focus
             )

    assert after_l.summary_scroll_x == 2

    assert {:noreply, after_d} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "d", modifiers: [], kind: "press"},
               summary_focus
             )

    assert after_d.summary_scroll_x == 0
    assert after_d.selected_service == state.selected_service
  end

  test "logs focus cycling updates the filter tabs" do
    state = sample_tui_state(:logs)

    assert {:noreply, filter_focus} =
             NixSwarm.TUI.handle_event(%Event.Key{code: "back_tab", kind: "press"}, state)

    assert filter_focus.focused_container == :logs_filter

    assert {:noreply, next_filter} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "right", modifiers: [], kind: "press"},
               filter_focus
             )

    assert next_filter.log_filter == :errors
  end

  test "mouse clicks and wheel target views, rows, and logs" do
    state =
      sample_tui_state(:map)
      |> Map.put(:viewport_width, 140)
      |> Map.put(:viewport_height, 60)

    assert {:noreply, services_view} =
             NixSwarm.TUI.handle_event(
               %Event.Mouse{kind: "down", button: "left", x: 38, y: 1},
               state
             )

    assert services_view.active_view == :services
    assert services_view.focused_container == :services_table

    assert {:noreply, selected_row} =
             NixSwarm.TUI.handle_event(
               %Event.Mouse{kind: "down", button: "left", x: 2, y: 9},
               services_view
             )

    assert selected_row.selected_service == "proxy"
    assert selected_row.focused_container == :services_table

    assert {:noreply, scrolled_logs} =
             NixSwarm.TUI.handle_event(
               %Event.Mouse{kind: "scroll_down", x: 60, y: 40},
               selected_row
             )

    assert scrolled_logs.focused_container == :services_logs
    assert scrolled_logs.content_scroll_y == 1
    assert scrolled_logs.log_scroll == 1
  end

  test "log search, tail toggle, sorting, and export actions update state" do
    state = sample_tui_state(:services)

    assert {:noreply, tail_off} =
             NixSwarm.TUI.handle_event(%Event.Key{code: "t", modifiers: [], kind: "press"}, state)

    refute tail_off.log_tail?

    assert {:noreply, prompt_state} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "/", modifiers: [], kind: "press"},
               tail_off
             )

    assert prompt_state.prompt.kind == :log_search

    searched_state =
      ["s", "e", "l", "e", "c", "t", "e", "d"]
      |> Enum.reduce(prompt_state, fn key, current_state ->
        assert {:noreply, next_state} =
                 NixSwarm.TUI.handle_event(%Event.Key{code: key, kind: "press"}, current_state)

        next_state
      end)

    assert {:noreply, searched_state} =
             NixSwarm.TUI.handle_event(%Event.Key{code: "enter", kind: "press"}, searched_state)

    assert searched_state.log_search_query == "selected"
    assert searched_state.content_scroll_y > 0

    assert {:noreply, sorted_state} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "o", modifiers: [], kind: "press"},
               searched_state
             )

    assert sorted_state.service_sort == {:replicas, :asc}

    assert {:stop, log_copy_state} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "C", modifiers: [], kind: "press"},
               sorted_state
             )

    assert match?({:copy_text, "service-logs-gitea", _}, log_copy_state.pending_action)
    assert elem(log_copy_state.pending_action, 2) =~ "selected service log entry"

    assert {:stop, row_export_state} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "U", modifiers: [], kind: "press"},
               sorted_state
             )

    assert match?({:export_text, "service-row-gitea", _}, row_export_state.pending_action)
  end

  test "update hotkey tolerates rollout targets missing from the current cluster view" do
    state =
      sample_tui_state(:services)
      |> put_in([:overview, :members, :configured_nodes], [:"nix-swarm@node-b.lan"])
      |> put_in([:overview, :members, :live_nodes], [:"nix-swarm@node-b.lan"])
      |> put_in(
        [:overview, :members, :deploy_hosts],
        %{
          :"nix-swarm@node-b.lan" => "root@node-b",
          :"nix-swarm@ghost.lan" => "root@node-b"
        }
      )

    assert {:noreply, updated_state} =
             NixSwarm.TUI.handle_event(%Event.Key{code: "u", modifiers: [], kind: "press"}, state)

    assert updated_state.rollout_confirmation != nil
    assert updated_state.rollout_confirmation.target_hosts == ["root@node-b"]

    assert updated_state.rollout_confirmation.current_versions == [
             {"nix-swarm@node-b.lan", "v1.0.1"}
           ]
  end

  test "machines view shows when the selected node differs from the control node version" do
    terminal = ExRatatui.init_test_terminal(220, 40)

    state =
      sample_tui_state(:machines)
      |> put_in([:overview, :members, :queried_node], :"nix-swarm@node-b.lan")
      |> put_in([:overview, :status, :queried_node], :"nix-swarm@node-b.lan")

    :ok = ExRatatui.draw(terminal, NixSwarm.TUI.scene(state, 220, 40))
    content = ExRatatui.get_buffer_content(terminal)

    assert content =~ "update available: yes"
    assert content =~ "control node reports v1.0.1"
    assert content =~ "v1.0.0 *"
  end

  test "rollout confirmation can be cancelled with escape" do
    state =
      sample_tui_state(:services)
      |> Map.put(:rollout_confirmation, %{deploy_opts: [], target_hosts: ["root@node-a"]})
      |> Map.put(:flash, "rollout ready")

    assert {:noreply, cancelled_state} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "esc", modifiers: [], kind: "press"},
               state
             )

    assert cancelled_state.rollout_confirmation == nil
    assert cancelled_state.flash == "rollout cancelled"
  end

  test "service and machine actions require a selected row" do
    service_state =
      sample_tui_state(:services)
      |> Map.put(:selected_service, nil)

    assert {:noreply, select_service_state} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "x", modifiers: [], kind: "press"},
               service_state
             )

    assert select_service_state.flash == "select a service before restarting"

    machine_state =
      sample_tui_state(:machines)
      |> Map.put(:selected_node, nil)

    assert {:noreply, select_machine_state} =
             NixSwarm.TUI.handle_event(
               %Event.Key{code: "R", modifiers: [], kind: "press"},
               machine_state
             )

    assert select_machine_state.flash == "select a machine before restarting"
  end

  defp service_placement_converged?(cluster, service_name) do
    status = :rpc.call(hd(cluster.nodes), NixSwarm.API, :cluster_status, [])

    status.placements
    |> Map.get(service_name, [])
    |> Enum.all?(fn slot ->
      Enum.all?(cluster.nodes, fn node ->
        expected = if node == slot.owner, do: "running", else: "stopped"
        NixSwarm.TestCluster.unit_state(cluster.root, node, slot.unit) == expected
      end)
    end)
  end

  defp service_fully_stopped?(cluster, service_name) do
    status = :rpc.call(hd(cluster.nodes), NixSwarm.API, :cluster_status, [])

    status.placements
    |> Map.get(service_name, [])
    |> Enum.all?(fn slot ->
      Enum.all?(cluster.nodes, fn node ->
        NixSwarm.TestCluster.unit_state(cluster.root, node, slot.unit) == "stopped"
      end)
    end)
  end

  defp sample_tui_state(active_view) do
    nodes = [:"nix-swarm@node-a.lan", :"nix-swarm@node-b.lan"]

    focused_container =
      case active_view do
        :dashboard -> :dashboard_services
        :map -> :map_canvas
        :machines -> :machines_table
        :services -> :services_table
        :logs -> :logs_content
      end

    %{
      remote: %{target: "nix-swarm@test"},
      lines: 50,
      refresh_ms: 3_000,
      active_view: active_view,
      selected_service: "gitea",
      selected_node: :"nix-swarm@node-a.lan",
      update_fun: &NixSwarm.Update.run/2,
      diagnostic: %{target: "nix-swarm@test", connect_result: true},
      overview: %{
        members: %{
          queried_node: :"nix-swarm@node-a.lan",
          configured_nodes: nodes,
          live_nodes: nodes,
          deploy_hosts: %{
            :"nix-swarm@node-a.lan" => "root@node-a",
            :"nix-swarm@node-b.lan" => "root@node-b"
          }
        },
        status: %{
          queried_node: :"nix-swarm@node-a.lan",
          live_nodes: nodes,
          placements: %{
            "gitea" => [
              %{slot: 0, owner: :"nix-swarm@node-a.lan", unit: "gitea@0.service"},
              %{slot: 1, owner: :"nix-swarm@node-b.lan", unit: "gitea@1.service"}
            ],
            "proxy" => [
              %{slot: 0, owner: :"nix-swarm@node-b.lan", unit: "proxy@0.service"}
            ]
          },
          nodes: [
            {:"nix-swarm@node-a.lan",
             %{
               version: "v1.0.0",
               metrics: %{uptime: 120},
               network_info: %{ips: ["10.0.0.1"], ports: [22, 443]},
               services: [
                 %{
                   name: "gitea",
                   local_owned_slots: [0],
                   units: [
                     %{
                       slot: 0,
                       owner: :"nix-swarm@node-a.lan",
                       unit: "gitea@0.service",
                       status: :running
                     },
                     %{
                       slot: 1,
                       owner: :"nix-swarm@node-b.lan",
                       unit: "gitea@1.service",
                       status: :stopped
                     }
                   ]
                 }
               ]
             }},
            {:"nix-swarm@node-b.lan",
             %{
               version: "v1.0.1",
               metrics: %{uptime: 240},
               network_info: %{ips: ["10.0.0.2"], ports: [22, 80, 443]},
               services: [
                 %{
                   name: "gitea",
                   desired_state: :running,
                   local_owned_slots: [1],
                   units: [
                     %{
                       slot: 0,
                       owner: :"nix-swarm@node-a.lan",
                       unit: "gitea@0.service",
                       status: :stopped
                     },
                     %{
                       slot: 1,
                       owner: :"nix-swarm@node-b.lan",
                       unit: "gitea@1.service",
                       status: :running
                     }
                   ]
                 },
                 %{
                   name: "proxy",
                   desired_state: :running,
                   local_owned_slots: [0],
                   units: [
                     %{
                       slot: 0,
                       owner: :"nix-swarm@node-b.lan",
                       unit: "proxy@0.service",
                       status: :running
                     }
                   ]
                 }
               ]
             }}
          ]
        }
      },
      service_logs: [
        {:"nix-swarm@node-a.lan",
         [%{slot: 0, unit: "gitea@0.service", logs: "selected service log entry"}]}
      ],
      cluster_logs: "selected machine log entry",
      cluster_event_logs:
        "== nix-swarm@node-a.lan ==\n01:01:01 cluster healthy\n01:01:02 error machine issue\n\n== nix-swarm@node-b.lan ==\n01:01:03 warning service flap",
      log_filter: :all,
      log_scroll: 0,
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
      node_metric_samples: %{},
      node_metrics_by_node: %{},
      service_metric_samples: %{},
      service_metrics_by_service: %{},
      last_rollout: nil,
      rollout_confirmation: nil,
      loading: false,
      busy: nil,
      job_ref: nil,
      flash: "ready",
      last_error: nil,
      last_refresh_at: "2026-04-26 10:00:00",
      last_snapshot_ms: System.monotonic_time(:millisecond),
      last_input_at_ms: nil,
      job_started_at_ms: nil,
      pending_refresh: nil,
      tick_count: 0,
      test_pid: nil,
      prompt: nil,
      action_confirmation: nil,
      help_overlay: false,
      log_tail?: true,
      log_search_query: nil,
      log_search_match_index: 0,
      service_sort: {:name, :asc},
      machine_sort: {:host, :asc},
      summary_scroll_x: 0,
      summary_scroll_y: 0,
      content_scroll_x: 0,
      content_scroll_y: 0,
      config_paths: NixSwarm.ConfigFiles.defaults("."),
      deploy_fun: &NixSwarm.Deploy.run/1,
      owner_pid: nil,
      content_mode: :logs,
      apply_result: nil,
      pending_machine_actions: %{},
      pending_action: nil,
      focused_container: focused_container,
      viewport_width: 140,
      viewport_height: 40
    }
  end
end
