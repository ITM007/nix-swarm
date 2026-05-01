defmodule NixSwarm.TUI do
  @moduledoc false

  use ExRatatui.App

  alias ExRatatui.Event
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Gauge, Paragraph, Table, Tabs, Throbber}
  alias NixSwarm.{Ascii, ClusterLogs, ConfigFiles, Deploy, Remote, Update}

  @default_lines 50
  @default_refresh_ms 3_000
  @views [:dashboard, :map, :machines, :services, :logs]
  @log_filters [:all, :errors, :selected_machine, :selected_service]
  @focusable_containers %{
    dashboard: [:dashboard_services],
    map: [:map_canvas],
    machines: [:machines_table, :machines_summary, :machines_logs],
    services: [:services_table, :services_summary, :services_logs],
    logs: [:logs_content, :logs_filter]
  }
  @input_refresh_debounce_ms 750

  @type state :: map()

  def run(opts) do
    with_terminal_logging_suppressed(fn ->
      ensure_runtime_supported!()
      remote = Remote.options!(opts)

      config_paths =
        ConfigFiles.defaults(Keyword.get(opts, :source))
        |> Map.merge(%{
          cluster_file:
            Keyword.get(
              opts,
              :cluster_file,
              ConfigFiles.defaults(Keyword.get(opts, :source)).cluster_file
            ),
          machines_dir:
            Keyword.get(
              opts,
              :machines_dir,
              ConfigFiles.defaults(Keyword.get(opts, :source)).machines_dir
            ),
          services_dir:
            Keyword.get(
              opts,
              :services_dir,
              ConfigFiles.defaults(Keyword.get(opts, :source)).services_dir
            ),
          remote_path: Keyword.get(opts, :remote_path, Deploy.defaults().remote_path),
          nixos_dir: Keyword.get(opts, :nixos_dir, Deploy.defaults().nixos_dir)
        })

      # Establish connection in the main process before starting the UI
      # This ensures net_kernel is tied to the long-running main process
      # rather than transient refresh tasks.
      Remote.connect!(remote)

      run_session(
        [
          name: nil,
          remote: remote,
          lines: Keyword.get(opts, :lines, @default_lines),
          refresh_ms: Keyword.get(opts, :refresh_ms, @default_refresh_ms),
          config_paths: config_paths,
          owner_pid: self(),
          deploy_fun: Keyword.get(opts, :deploy_fun, &Deploy.run/1)
        ],
        %{},
        Keyword.get(opts, :editor_runner, &run_system_editor/1)
      )
    end)
  end

  @doc false
  def with_terminal_logging_suppressed(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :none)

    try do
      fun.()
    after
      Logger.configure(level: previous_level)
    end
  end

  @doc false
  def runtime_supported?(app_dir_fun \\ &Application.app_dir/2) do
    app_dir_fun.(:ex_ratatui, "priv/native")
    |> File.dir?()
  end

  @doc false
  def runtime_support_error(app_dir_fun \\ &Application.app_dir/2) do
    native_dir = app_dir_fun.(:ex_ratatui, "priv/native")

    """
    the TUI requires a Mix or release runtime with the ex_ratatui native library available on disk

    run one of these instead:
      mix run -e 'NixSwarm.CLI.main(System.argv())' -- --target NODE
      nix-swarm --target NODE

    expected ex_ratatui native directory:
      #{native_dir}
    """
    |> String.trim()
  end

  defp ensure_runtime_supported!(app_dir_fun \\ &Application.app_dir/2) do
    unless runtime_supported?(app_dir_fun) do
      raise RuntimeError, message: runtime_support_error(app_dir_fun)
    end
  end

  @impl true
  def mount(opts) do
    resume_state = Keyword.get(opts, :resume_state, %{})

    state =
      %{
        remote: Keyword.fetch!(opts, :remote),
        lines: Keyword.get(opts, :lines, @default_lines),
        refresh_ms: Keyword.get(opts, :refresh_ms, @default_refresh_ms),
        active_view: :dashboard,
        selected_service: nil,
        selected_node: nil,
        update_fun: Keyword.get(opts, :update_fun, &Update.run/2),
        diagnostic: nil,
        overview: nil,
        service_logs: [],
        cluster_logs: "",
        cluster_event_logs: "",
        log_scroll: 0,
        metrics_history: %{cpu: [], memory: [], disk: [], network: []},
        cluster_metrics: default_cluster_metrics(),
        metrics_sample: nil,
        node_metric_samples: %{},
        node_metrics_by_node: %{},
        service_metric_samples: %{},
        service_metrics_by_service: %{},
        last_rollout: nil,
        rollout_confirmation: nil,
        action_confirmation: nil,
        loading: false,
        busy: nil,
        job_ref: nil,
        job_started_at_ms: nil,
        pending_refresh: nil,
        config_paths:
          Keyword.get(opts, :config_paths, ConfigFiles.defaults(Keyword.get(opts, :source, "."))),
        deploy_fun: Keyword.get(opts, :deploy_fun, &Deploy.run/1),
        owner_pid: Keyword.get(opts, :owner_pid),
        prompt: nil,
        help_overlay: false,
        content_mode: :logs,
        log_filter: :all,
        log_tail?: true,
        log_search_query: nil,
        log_search_match_index: 0,
        service_sort: {:name, :asc},
        machine_sort: {:host, :asc},
        summary_scroll_x: 0,
        summary_scroll_y: 0,
        content_scroll_x: 0,
        content_scroll_y: 0,
        focused_container: nil,
        viewport_width: nil,
        viewport_height: nil,
        pending_machine_actions: %{},
        pending_operator_action: nil,
        apply_result: nil,
        pending_action: nil,
        flash: "connecting to target...",
        last_error: nil,
        last_refresh_at: nil,
        last_snapshot_ms: nil,
        last_input_at_ms: nil,
        tick_count: 0,
        test_pid: Keyword.get(opts, :test_pid)
      }
      |> Map.merge(resume_state)
      |> ensure_viewport(Keyword.get(opts, :test_mode))
      |> normalize_focused_container()

    schedule_tick(100)
    schedule_refresh(state.refresh_ms)
    send(self(), :refresh_now)

    {:ok, state}
  end

  @impl true
  def render(state, frame) do
    scene(state, frame.width, frame.height)
  end

  def scene(state, width, height) do
    area = %Rect{x: 0, y: 0, width: width, height: height}

    [header_area, body_area, footer_area] =
      Layout.split(area, :vertical, [
        {:length, 3},
        {:min, 0},
        {:length, 3}
      ])

    [tabs_area, status_area] =
      Layout.split(header_area, :horizontal, [
        {:percentage, 40},
        {:percentage, 60}
      ])

    [{tabs_widget(state), tabs_area}, {status_widget(state), status_area}]
    |> Kernel.++(body_widgets(state, body_area))
    |> Kernel.++([{footer_widget(state), footer_area}])
  end

  @impl true
  def handle_event(%Event.Key{code: "enter", kind: "press"}, %{prompt: prompt} = state)
      when not is_nil(prompt) do
    state
    |> submit_prompt()
    |> event_transition()
  end

  def handle_event(%Event.Key{code: "esc", kind: "press"}, %{prompt: prompt} = state)
      when not is_nil(prompt) do
    {:noreply, state |> cancel_prompt() |> note_input() |> maybe_flush_pending_refresh()}
  end

  def handle_event(%Event.Key{code: "backspace", kind: "press"}, %{prompt: prompt} = state)
      when not is_nil(prompt) do
    {:noreply, state |> prompt_backspace() |> note_input()}
  end

  def handle_event(%Event.Key{code: "space", kind: "press"}, %{prompt: prompt} = state)
      when not is_nil(prompt) do
    {:noreply, state |> prompt_append(" ") |> note_input()}
  end

  def handle_event(%Event.Key{code: code, kind: "press"}, %{prompt: prompt} = state)
      when not is_nil(prompt) and is_binary(code) and byte_size(code) == 1 do
    {:noreply, state |> prompt_append(code) |> note_input()}
  end

  def handle_event(%Event.Mouse{}, %{prompt: prompt} = state) when not is_nil(prompt) do
    {:noreply, note_input(state)}
  end

  def handle_event(
        %Event.Key{code: code, modifiers: modifiers, kind: "press"},
        %{help_overlay: true} = state
      )
      when code in ["?", "esc", "q"] or (code == "/" and modifiers == ["shift"]) do
    {:noreply, state |> close_help_overlay() |> note_input() |> maybe_flush_pending_refresh()}
  end

  def handle_event(%Event.Key{kind: "press"}, %{help_overlay: true} = state) do
    {:noreply, note_input(state)}
  end

  def handle_event(%Event.Mouse{}, %{help_overlay: true} = state) do
    {:noreply, note_input(state)}
  end

  def handle_event(
        %Event.Key{code: "c", kind: "press"},
        %{rollout_confirmation: confirmation} = state
      )
      when not is_nil(confirmation) do
    {:noreply, state |> set_rollout_scope(:cluster) |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "m", kind: "press"},
        %{rollout_confirmation: confirmation} = state
      )
      when not is_nil(confirmation) do
    {:noreply, state |> set_rollout_scope(:selected_machine) |> note_input()}
  end

  def handle_event(
        %Event.Key{code: code, kind: "press"},
        %{rollout_confirmation: confirmation} = state
      )
      when not is_nil(confirmation) and code in ["u", "enter"] do
    {:noreply, state |> confirm_rollout() |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "esc", kind: "press"},
        %{rollout_confirmation: confirmation} = state
      )
      when not is_nil(confirmation) do
    {:noreply, state |> cancel_rollout_confirmation() |> note_input()}
  end

  def handle_event(%Event.Key{kind: "press"}, %{rollout_confirmation: confirmation} = state)
      when not is_nil(confirmation) do
    {:noreply, note_input(state)}
  end

  def handle_event(%Event.Mouse{}, %{rollout_confirmation: confirmation} = state)
      when not is_nil(confirmation) do
    {:noreply, note_input(state)}
  end

  def handle_event(
        %Event.Key{code: code, kind: "press"},
        %{action_confirmation: confirmation} = state
      )
      when not is_nil(confirmation) and code in ["y", "enter"] do
    {:noreply, state |> confirm_action_confirmation() |> note_input()}
  end

  def handle_event(
        %Event.Key{code: code, kind: "press"},
        %{action_confirmation: confirmation} = state
      )
      when not is_nil(confirmation) and code in ["n", "esc"] do
    {:noreply, state |> cancel_action_confirmation() |> note_input()}
  end

  def handle_event(%Event.Key{kind: "press"}, %{action_confirmation: confirmation} = state)
      when not is_nil(confirmation) do
    {:noreply, note_input(state)}
  end

  def handle_event(%Event.Mouse{}, %{action_confirmation: confirmation} = state)
      when not is_nil(confirmation) do
    {:noreply, note_input(state)}
  end

  def handle_event(%Event.Key{code: code, modifiers: modifiers, kind: "press"}, state)
      when code in ["?"] or (code == "/" and modifiers == ["shift"]) do
    {:noreply, state |> open_help_overlay() |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "/", modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:machines, :services, :logs] and modifiers in [nil, []] do
    {:noreply, state |> open_log_search_prompt() |> note_input()}
  end

  def handle_event(
        %Event.Key{code: code, modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:machines, :services, :logs] and code in ["n", "N"] and
             modifiers in [nil, [], ["shift"]] do
    direction = if code == "N", do: -1, else: 1
    {:noreply, state |> jump_log_search(direction) |> note_input()}
  end

  def handle_event(
        %Event.Key{code: code, modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:machines, :services, :logs] and code in ["t", "T"] and
             modifiers in [nil, [], ["shift"]] do
    {:noreply, state |> toggle_log_tail() |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "o", modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:dashboard, :services, :machines] and modifiers in [nil, []] do
    {:noreply, state |> cycle_table_sort() |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "O", modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:dashboard, :services, :machines] and modifiers in [nil, []] do
    {:noreply, state |> reverse_table_sort() |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "C", modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:machines, :services, :logs] and modifiers in [nil, []] do
    external_action_transition(build_log_action(state, :copy))
  end

  def handle_event(
        %Event.Key{code: "E", modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:machines, :services, :logs] and modifiers in [nil, []] do
    external_action_transition(build_log_action(state, :export))
  end

  def handle_event(
        %Event.Key{code: "Y", modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:dashboard, :services, :machines] and modifiers in [nil, []] do
    external_action_transition(build_selection_action(state, :copy))
  end

  def handle_event(
        %Event.Key{code: "U", modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:dashboard, :services, :machines] and modifiers in [nil, []] do
    external_action_transition(build_selection_action(state, :export))
  end

  def handle_event(%Event.Key{code: code, kind: "press"}, state) when code in ["q", "esc"] do
    {:stop, state}
  end

  def handle_event(%Event.Key{code: "back_tab", kind: kind}, state)
      when kind in [nil, "press", "repeat"] do
    {:noreply, state |> cycle_focused_container() |> note_input()}
  end

  def handle_event(%Event.Key{code: "tab", modifiers: ["shift"], kind: kind}, state)
      when kind in [nil, "press", "repeat"] do
    {:noreply, state |> cycle_focused_container() |> note_input()}
  end

  def handle_event(%Event.Key{code: "tab", kind: kind}, state)
      when kind in [nil, "press", "repeat"] do
    {:noreply, state |> switch_view(next_view(state.active_view)) |> note_input()}
  end

  def handle_event(%Event.Key{code: code, modifiers: modifiers, kind: "press"}, state)
      when code in ["up", "k"] and modifiers in [nil, []] do
    {:noreply, state |> move_focused_container(:up) |> note_input()}
  end

  def handle_event(%Event.Key{code: code, modifiers: modifiers, kind: "press"}, state)
      when code in ["down", "j"] and modifiers in [nil, []] do
    {:noreply, state |> move_focused_container(:down) |> note_input()}
  end

  def handle_event(%Event.Key{code: code, modifiers: modifiers, kind: "press"}, state)
      when code in ["left", "h"] and modifiers in [nil, []] do
    {:noreply, state |> move_focused_container(:left) |> note_input()}
  end

  def handle_event(%Event.Key{code: code, modifiers: modifiers, kind: "press"}, state)
      when code in ["right", "l"] and modifiers in [nil, []] do
    {:noreply, state |> move_focused_container(:right) |> note_input()}
  end

  def handle_event(%Event.Key{code: code, modifiers: modifiers, kind: "press"}, state)
      when code in ["K", "J"] and modifiers in [nil, []] do
    direction = if code == "K", do: :up, else: :down
    {:noreply, state |> move_focused_container(direction) |> note_input()}
  end

  def handle_event(%Event.Key{code: code, modifiers: modifiers, kind: "press"}, state)
      when code in ["H", "L"] and modifiers in [nil, []] do
    direction = if code == "H", do: :left, else: :right
    {:noreply, state |> move_focused_container(direction) |> note_input()}
  end

  def handle_event(%Event.Key{code: code, modifiers: ["shift"], kind: "press"}, state)
      when code in ["up", "down", "left", "right", "h", "j", "k", "l"] do
    direction =
      case code do
        "up" -> :up
        "k" -> :up
        "left" -> :left
        "h" -> :left
        "down" -> :down
        "j" -> :down
        "right" -> :right
        "l" -> :right
      end

    {:noreply, state |> move_focused_container(direction) |> note_input()}
  end

  def handle_event(%Event.Mouse{kind: "down", button: "left", x: x, y: y}, state) do
    {:noreply, state |> handle_mouse_click(x, y) |> note_input()}
  end

  def handle_event(%Event.Mouse{kind: kind, x: x, y: y}, state)
      when kind in ["scroll_up", "scroll_down", "scroll_left", "scroll_right"] do
    {:noreply, state |> handle_mouse_scroll(kind, x, y) |> note_input()}
  end

  def handle_event(%Event.Resize{width: width, height: height}, state) do
    {:noreply, %{state | viewport_width: width, viewport_height: height}}
  end

  def handle_event(
        %Event.Key{code: "f", modifiers: modifiers, kind: "press"},
        %{active_view: :logs} = state
      )
      when modifiers in [nil, []] do
    {:noreply, state |> cycle_log_filter() |> note_input()}
  end

  def handle_event(
        %Event.Key{code: code, modifiers: modifiers, kind: "press"},
        %{active_view: :logs} = state
      )
      when code in ["1", "2", "3", "4"] and modifiers in [nil, []] do
    {:noreply, state |> set_log_filter(log_filter_for_key(code)) |> note_input()}
  end

  def handle_event(%Event.Key{code: "r", kind: "press"}, state) do
    {:noreply, state |> request_refresh(:manual) |> note_input()}
  end

  def handle_event(%Event.Key{code: "enter", kind: "press"}, state) do
    {:noreply, state |> request_refresh(:manual) |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "b", modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:dashboard, :services] and modifiers in [nil, []] do
    {:noreply, state |> request_service_action(:start) |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "b", modifiers: modifiers, kind: "press"},
        %{active_view: :machines} = state
      )
      when modifiers in [nil, []] do
    {:noreply, state |> request_node_service_action(:start) |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "z", modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:dashboard, :services] and modifiers in [nil, []] do
    {:noreply, state |> request_service_action(:stop) |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "z", modifiers: modifiers, kind: "press"},
        %{active_view: :machines} = state
      )
      when modifiers in [nil, []] do
    {:noreply, state |> request_node_service_action(:stop) |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "x", modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:dashboard, :services] and modifiers in [nil, []] do
    {:noreply, state |> request_restart() |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "x", modifiers: modifiers, kind: "press"},
        %{active_view: :machines} = state
      )
      when modifiers in [nil, []] do
    {:noreply, state |> request_node_service_action(:restart) |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "R", modifiers: modifiers, kind: "press"},
        %{active_view: :machines} = state
      )
      when modifiers in [nil, []] do
    {:noreply, state |> request_machine_action(:restart) |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "Z", modifiers: modifiers, kind: "press"},
        %{active_view: :machines} = state
      )
      when modifiers in [nil, []] do
    {:noreply, state |> request_machine_action(:shutdown) |> note_input()}
  end

  def handle_event(%Event.Key{code: "c", kind: "press"}, state) do
    {:noreply, state |> request_reconcile() |> note_input()}
  end

  def handle_event(%Event.Key{code: "u", kind: "press"}, state) do
    {:noreply, state |> request_update() |> note_input()}
  end

  def handle_event(%Event.Key{code: code, modifiers: modifiers, kind: "press"}, state)
      when code == "P" or (code == "p" and modifiers == ["shift"]) do
    {:noreply, state |> request_apply(false) |> note_input()}
  end

  def handle_event(%Event.Key{code: "y", kind: "press"}, state) do
    {:noreply, state |> request_apply(true) |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "a", modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:machines, :services] and modifiers in [nil, []] do
    {:noreply, state |> open_add_config_prompt(view) |> note_input()}
  end

  def handle_event(
        %Event.Key{code: "e", modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:machines, :services] and modifiers in [nil, []] do
    external_action_transition(edit_selected_config_file(state, view))
  end

  def handle_event(
        %Event.Key{code: "d", modifiers: modifiers, kind: "press"},
        %{active_view: view} = state
      )
      when view in [:machines, :services] and modifiers in [nil, []] do
    {:noreply, state |> delete_selected_config(view) |> note_input()}
  end

  def handle_event(_event, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule_tick(100)
    next = %{state | tick_count: state.tick_count + 1}

    if tick_needs_render?(state) do
      {:noreply, next}
    else
      {:noreply, next, render?: false}
    end
  end

  def handle_info(:refresh, state) do
    schedule_refresh(state.refresh_ms)

    cond do
      modal_open?(state) ->
        {:noreply, queue_refresh(state, :auto), render?: false}

      state.job_ref ->
        {:noreply, state, render?: false}

      recent_input?(state) ->
        schedule_deferred_refresh()
        {:noreply, state, render?: false}

      true ->
        {:noreply, request_refresh(state, :auto)}
    end
  end

  def handle_info(:refresh_now, state) do
    {:noreply, request_refresh(state, :initial)}
  end

  def handle_info(:deferred_refresh, state) do
    cond do
      modal_open?(state) ->
        {:noreply, queue_refresh(state, :auto), render?: false}

      state.job_ref ->
        {:noreply, state, render?: false}

      recent_input?(state) ->
        schedule_deferred_refresh()
        {:noreply, state, render?: false}

      state.pending_refresh ->
        {:noreply, flush_pending_refresh(state)}

      true ->
        {:noreply, request_refresh(state, :auto)}
    end
  end

  def handle_info({:job_result, ref, {:ok, payload}}, %{job_ref: ref} = state) do
    cond do
      stale_auto_refresh_result?(state) ->
        updated_state =
          state
          |> Map.put(:loading, false)
          |> Map.put(:busy, nil)
          |> Map.put(:job_ref, nil)
          |> Map.put(:job_started_at_ms, nil)
          |> queue_refresh(:auto)
          |> maybe_run_pending_operator_action()

        {:noreply, maybe_flush_pending_refresh(updated_state)}

      modal_open?(state) and refresh_job?(state.busy) ->
        updated_state =
          state
          |> Map.put(:loading, false)
          |> Map.put(:busy, nil)
          |> Map.put(:job_ref, nil)
          |> Map.put(:job_started_at_ms, nil)
          |> queue_refresh(:auto)

        {:noreply, updated_state, render?: false}

      true ->
        updated_state =
          state
          |> Map.put(:loading, false)
          |> Map.put(:busy, nil)
          |> Map.put(:job_ref, nil)
          |> Map.put(:job_started_at_ms, nil)
          |> Map.put(:flash, Map.get(payload, :flash, state.flash))
          |> Map.put(:last_error, nil)
          |> Map.put(:last_rollout, Map.get(payload, :rollout, state.last_rollout))
          |> Map.put(:apply_result, Map.get(payload, :apply_result, state.apply_result))
          |> apply_snapshot(payload.snapshot)
          |> maybe_run_pending_operator_action()

        maybe_notify_test(updated_state, payload)
        {:noreply, maybe_flush_pending_refresh(updated_state)}
    end
  end

  def handle_info({:job_result, ref, {:error, message}}, %{job_ref: ref} = state) do
    if modal_open?(state) and refresh_job?(state.busy) do
      updated_state =
        state
        |> Map.put(:loading, false)
        |> Map.put(:busy, nil)
        |> Map.put(:job_ref, nil)
        |> Map.put(:job_started_at_ms, nil)
        |> queue_refresh(:auto)

      {:noreply, updated_state, render?: false}
    else
      updated_state =
        %{
          state
          | loading: false,
            busy: nil,
            job_ref: nil,
            job_started_at_ms: nil,
            flash: "last action failed",
            last_error: message
        }
        |> maybe_run_pending_operator_action()

      maybe_notify_test(updated_state, %{error: message})
      {:noreply, maybe_flush_pending_refresh(updated_state)}
    end
  end

  def handle_info({:job_result, _ref, _result}, state) do
    {:noreply, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp request_refresh(%{job_ref: nil} = state, trigger) do
    launch_job(state, {:refresh, trigger}, fn ->
      snapshot =
        fetch_snapshot(state.remote, state.lines, state.selected_service, state.selected_node)

      %{
        snapshot: snapshot,
        flash: refresh_message(snapshot, trigger)
      }
    end)
  end

  defp request_refresh(state, trigger), do: queue_refresh(state, trigger)

  defp request_service_action(%{selected_service: nil} = state, action) do
    put_flash(state, "select a service before #{service_action_verb(action)}")
  end

  defp request_service_action(%{job_ref: nil, selected_service: service} = state, action) do
    launch_service_action(state, action, service)
  end

  defp request_service_action(%{selected_service: service} = state, action) do
    queue_operator_action(
      state,
      {:service_action, action, service},
      "#{service_action_label(action)} queued for #{service}"
    )
  end

  defp launch_service_action(state, action, service) do
    launch_job(state, {action, service}, fn ->
      node = Remote.connect!(state.remote)
      results = Remote.rpc!(node, NixSwarm.API, service_action_api(action), [service])
      snapshot = fetch_snapshot(state.remote, state.lines, service, state.selected_node)

      %{
        snapshot: snapshot,
        flash: service_action_message(action, service, results)
      }
    end)
  end

  defp request_node_service_action(%{selected_node: nil} = state, action) do
    put_flash(state, "select a machine before #{service_action_verb(action)} a local service")
  end

  defp request_node_service_action(%{selected_service: nil} = state, action) do
    put_flash(state, "select a service before #{service_action_verb(action)} it on one machine")
  end

  defp request_node_service_action(
         %{job_ref: nil, selected_node: node, selected_service: service} = state,
         action
       ) do
    launch_node_service_action(state, action, node, service)
  end

  defp request_node_service_action(
         %{selected_node: node, selected_service: service} = state,
         action
       ) do
    queue_operator_action(
      state,
      {:node_service_action, action, node, service},
      "#{service_action_label(action)} queued for #{service} on #{node_hostname(state.overview, node)}"
    )
  end

  defp launch_node_service_action(state, action, node, service) do
    launch_job(state, {:node_service_action, action, node, service}, fn ->
      target_node = Remote.connect!(state.remote)

      result =
        Remote.rpc!(target_node, NixSwarm.API, node_service_action_api(action), [node, service])

      snapshot = fetch_snapshot(state.remote, state.lines, service, node)

      %{
        snapshot: snapshot,
        flash:
          node_service_action_message(
            action,
            service,
            node,
            result,
            snapshot.overview || state.overview
          )
      }
    end)
  end

  defp request_restart(state), do: request_service_action(state, :restart)

  defp request_machine_action(%{selected_node: nil} = state, action) do
    put_flash(state, "select a machine before #{machine_action_verb(action)}")
  end

  defp request_machine_action(
         %{job_ref: nil, action_confirmation: nil, selected_node: node} = state,
         action
       ) do
    open_machine_action_confirmation(state, action, node)
  end

  defp request_machine_action(%{selected_node: node} = state, action) do
    queue_operator_action(
      state,
      {:machine_action, action, node},
      "#{machine_action_label(action)} queued for #{node_hostname(state.overview, node)}"
    )
  end

  defp open_machine_action_confirmation(state, action, node) do
    %{state | action_confirmation: build_action_confirmation(action, node, state.overview)}
    |> put_flash(
      "#{machine_action_label(action)} ready: press y or enter to confirm, esc to cancel"
    )
  end

  defp confirm_action_confirmation(%{action_confirmation: %{action: action, node: node}} = state) do
    launch_job(
      state
      |> Map.put(:action_confirmation, nil)
      |> put_pending_machine_action(node, action),
      {action, node},
      fn ->
        target_node = Remote.connect!(state.remote)
        result = Remote.rpc!(target_node, NixSwarm.API, machine_action_api(action), [node])

        snapshot =
          if target_node == node do
            current_state_snapshot(state)
          else
            fetch_snapshot(state.remote, state.lines, state.selected_service, node)
          end

        %{
          snapshot: snapshot,
          flash: machine_action_message(action, node, result, snapshot.overview || state.overview)
        }
      end
    )
  end

  defp confirm_action_confirmation(state), do: state

  defp cancel_action_confirmation(state) do
    %{state | action_confirmation: nil}
    |> put_flash("machine action cancelled")
  end

  defp request_reconcile(%{job_ref: nil} = state) do
    launch_reconcile(state)
  end

  defp request_reconcile(state) do
    queue_operator_action(state, :reconcile, "reconcile queued")
  end

  defp launch_reconcile(state) do
    launch_job(state, :reconcile, fn ->
      node = Remote.connect!(state.remote)
      results = Remote.rpc!(node, NixSwarm.API, :reconcile_cluster, [])

      snapshot =
        fetch_snapshot(state.remote, state.lines, state.selected_service, state.selected_node)

      %{
        snapshot: snapshot,
        flash: reconcile_message(results)
      }
    end)
  end

  defp request_update(%{job_ref: nil, rollout_confirmation: nil} = state) do
    open_rollout_confirmation(state)
  end

  defp request_update(%{job_ref: nil} = state) do
    confirm_rollout(state)
  end

  defp request_update(state) do
    queue_operator_action(state, :update, "cluster update queued")
  end

  defp open_rollout_confirmation(state) do
    state
    |> put_rollout_confirmation(default_rollout_scope(state))
    |> put_flash("rollout ready: press u or enter to confirm, esc to cancel")
  end

  defp confirm_rollout(%{rollout_confirmation: %{deploy_opts: deploy_opts, scope: scope}} = state) do
    launch_job(%{state | rollout_confirmation: nil}, {:update, scope}, fn ->
      update_result = state.update_fun.(deploy_opts, state.remote)

      snapshot =
        fetch_snapshot(state.remote, state.lines, state.selected_service, state.selected_node)

      %{
        snapshot: snapshot,
        flash: update_message(update_result),
        rollout: update_result
      }
    end)
  end

  defp cancel_rollout_confirmation(state) do
    %{state | rollout_confirmation: nil}
    |> put_flash("rollout cancelled")
  end

  defp request_apply(%{job_ref: nil} = state, dry_run?) do
    launch_apply(state, dry_run?)
  end

  defp request_apply(state, dry_run?) do
    queue_operator_action(
      state,
      {:apply, dry_run?},
      if(dry_run?, do: "dry-run queued", else: "apply queued")
    )
  end

  defp launch_apply(state, dry_run?) do
    launch_job(state, if(dry_run?, do: :dry_run, else: :apply), fn ->
      result =
        state.deploy_fun.(
          source: state.config_paths.source,
          cluster_file: state.config_paths.cluster_file,
          machines_dir: state.config_paths.machines_dir,
          remote_path: state.config_paths.remote_path,
          nixos_dir: state.config_paths.nixos_dir,
          dry_run: dry_run?
        )

      snapshot =
        fetch_snapshot(state.remote, state.lines, state.selected_service, state.selected_node)

      %{
        snapshot: snapshot,
        flash: apply_message(result),
        apply_result: result
      }
    end)
  end

  defp service_action_api(:start), do: :start_service
  defp service_action_api(:stop), do: :stop_service
  defp service_action_api(:restart), do: :restart_service

  defp node_service_action_api(:start), do: :start_service_on_node
  defp node_service_action_api(:stop), do: :stop_service_on_node
  defp node_service_action_api(:restart), do: :restart_service_on_node

  defp machine_action_api(:restart), do: :restart_machine
  defp machine_action_api(:shutdown), do: :shutdown_machine

  defp service_action_label(:start), do: "start"
  defp service_action_label(:stop), do: "stop"
  defp service_action_label(:restart), do: "restart"

  defp service_action_verb(:start), do: "starting"
  defp service_action_verb(:stop), do: "stopping"
  defp service_action_verb(:restart), do: "restarting"

  defp machine_action_label(:restart), do: "restart"
  defp machine_action_label(:shutdown), do: "shutdown"

  defp machine_action_verb(:restart), do: "restarting"
  defp machine_action_verb(:shutdown), do: "shutting down"

  defp build_action_confirmation(action, node, overview) do
    %{
      action: action,
      node: node,
      title: "#{machine_action_label(action)} machine",
      message:
        "Selected machine: #{node_hostname(overview, node)} (#{Atom.to_string(node)})\nPress y or enter to confirm, esc or n to cancel."
    }
  end

  defp current_state_snapshot(state) do
    %{
      diagnostic: state.diagnostic,
      overview: state.overview,
      selected_service: state.selected_service,
      selected_node: state.selected_node,
      service_logs: state.service_logs,
      cluster_logs: state.cluster_logs,
      cluster_event_logs: state.cluster_event_logs,
      last_refresh_at: timestamp(),
      captured_at_ms: System.monotonic_time(:millisecond)
    }
  end

  defp cancel_prompt(state) do
    message =
      case get_in(state, [:prompt, :kind]) do
        :log_search -> "log search cancelled"
        _ -> "prompt cancelled"
      end

    %{state | prompt: nil}
    |> put_flash(message)
  end

  defp prompt_backspace(%{prompt: _prompt} = state) do
    update_in(state.prompt.value, fn value ->
      value
      |> String.to_charlist()
      |> Enum.drop(-1)
      |> to_string()
    end)
  end

  defp prompt_append(%{prompt: prompt} = state, suffix) do
    %{state | prompt: %{prompt | value: prompt.value <> suffix}}
  end

  defp submit_prompt(%{prompt: nil} = state), do: state

  defp submit_prompt(%{prompt: %{kind: :log_search, value: value}} = state) do
    state
    |> Map.put(:prompt, nil)
    |> apply_log_search(value)
  end

  defp submit_prompt(%{prompt: %{kind: :add_machine, value: value}} = state) do
    case parse_add_machine_input(value) do
      {:ok, node_name, deploy_host, labels} ->
        case ConfigFiles.add_machine(state.config_paths, node_name,
               deploy_host: deploy_host,
               labels: labels
             ) do
          {:ok, path} ->
            state
            |> Map.put(:prompt, nil)
            |> Map.put(:pending_action, external_action(:edit, "machine-file", path))
            |> put_flash("machine added: #{node_name}; opening #{Path.basename(path)}")

          {:error, message} ->
            put_error(state, message)
        end

      {:error, message} ->
        put_error(state, message)
    end
  end

  defp submit_prompt(%{prompt: %{kind: :add_service, value: value}} = state) do
    case parse_add_service_input(value) do
      {:ok, service_name, replicas, constraints, preferred_nodes} ->
        case ConfigFiles.add_service(state.config_paths, service_name,
               replicas: replicas,
               constraints: constraints,
               preferred_nodes: preferred_nodes
             ) do
          {:ok, path} ->
            state
            |> Map.put(:prompt, nil)
            |> Map.put(:pending_action, external_action(:edit, "service-file", path))
            |> put_flash("service added: #{service_name}; opening #{Path.basename(path)}")

          {:error, message} ->
            put_error(state, message)
        end

      {:error, message} ->
        put_error(state, message)
    end
  end

  defp submit_prompt(state) do
    %{state | prompt: nil}
    |> put_error("confirmation did not match")
  end

  defp build_rollout_confirmation(state, scope) do
    {target_hosts, target_nodes} = rollout_targets(state, scope)

    deploy_opts =
      rollout_base_opts(state)
      |> Keyword.put(:hosts, target_hosts)
      |> Keyword.put(:target_nodes, target_nodes)
      |> Update.effective_deploy_opts(%{overview: state.overview})

    %{
      scope: scope,
      available_scopes: rollout_available_scopes(state),
      deploy_opts: deploy_opts,
      target_hosts: target_hosts,
      target_nodes: target_nodes,
      prepared_at: timestamp(),
      current_versions: rollout_version_rows(state.overview, target_nodes)
    }
  end

  defp rollout_base_opts(state) do
    Deploy.defaults(state.config_paths.source)
    |> Enum.to_list()
    |> Keyword.drop([:hosts])
    |> Keyword.put(:cluster_file, state.config_paths.cluster_file)
    |> Keyword.put(:machines_dir, state.config_paths.machines_dir)
    |> Keyword.put(:remote_path, state.config_paths.remote_path)
    |> Keyword.put(:nixos_dir, state.config_paths.nixos_dir)
  end

  defp put_rollout_confirmation(state, scope) do
    %{state | rollout_confirmation: build_rollout_confirmation(state, scope)}
  end

  defp set_rollout_scope(%{rollout_confirmation: nil} = state, _scope), do: state

  defp set_rollout_scope(state, scope) do
    if scope in rollout_available_scopes(state) do
      state
      |> put_rollout_confirmation(scope)
      |> put_flash("rollout scope: #{rollout_scope_label(scope)}")
    else
      state
    end
  end

  defp default_rollout_scope(state) do
    if state.active_view == :machines and rollout_selected_machine_available?(state) do
      :selected_machine
    else
      :cluster
    end
  end

  defp rollout_available_scopes(state) do
    if rollout_selected_machine_available?(state) do
      [:cluster, :selected_machine]
    else
      [:cluster]
    end
  end

  defp rollout_selected_machine_available?(state) do
    not is_nil(state.selected_node) and is_binary(selected_node_deploy_host(state))
  end

  defp rollout_targets(state, :selected_machine) do
    case {state.selected_node, selected_node_deploy_host(state)} do
      {node, host} when is_atom(node) and is_binary(host) -> {[host], [Atom.to_string(node)]}
      _ -> rollout_targets(state, :cluster)
    end
  end

  defp rollout_targets(state, _scope) do
    target_hosts =
      rollout_base_opts(state)
      |> Update.effective_deploy_opts(%{overview: state.overview})
      |> Keyword.get(:hosts, [])

    target_nodes =
      case state.overview do
        nil ->
          []

        overview ->
          overview
          |> Map.get(:members, %{})
          |> Map.get(:live_nodes, [])
          |> Enum.map(&Atom.to_string/1)
      end

    {target_hosts, target_nodes}
  end

  defp launch_job(state, busy, fun) do
    ref = make_ref()
    owner = self()

    Task.start(fn ->
      send(owner, {:job_result, ref, execute_job(fun)})
    end)

    %{
      state
      | loading: true,
        busy: busy,
        job_ref: ref,
        job_started_at_ms: System.monotonic_time(:millisecond)
    }
  end

  defp execute_job(fun) do
    try do
      {:ok, fun.()}
    rescue
      error in [Remote.Error, RuntimeError, ArgumentError] ->
        {:error, Exception.message(error)}
    catch
      kind, reason ->
        {:error, "#{inspect(kind)}: #{inspect(reason)}"}
    end
  end

  defp queue_operator_action(state, action, message) do
    state
    |> Map.put(:pending_operator_action, action)
    |> put_flash(message)
  end

  defp maybe_run_pending_operator_action(state) do
    case Map.get(state, :pending_operator_action) do
      nil ->
        state

      action ->
        state
        |> Map.put(:pending_operator_action, nil)
        |> run_operator_action(action)
    end
  end

  defp run_operator_action(state, {:service_action, action, service}) do
    launch_service_action(%{state | selected_service: service}, action, service)
  end

  defp run_operator_action(state, {:node_service_action, action, node, service}) do
    launch_node_service_action(
      %{state | selected_node: node, selected_service: service},
      action,
      node,
      service
    )
  end

  defp run_operator_action(state, {:machine_action, action, node}) do
    open_machine_action_confirmation(%{state | selected_node: node}, action, node)
  end

  defp run_operator_action(state, :reconcile), do: launch_reconcile(state)
  defp run_operator_action(state, :update), do: open_rollout_confirmation(state)
  defp run_operator_action(state, {:apply, dry_run?}), do: launch_apply(state, dry_run?)

  defp fetch_snapshot(remote, lines, selected_service, selected_node) do
    diagnostic = Remote.diagnose_connection(remote, skip_port_checks: true)

    if Remote.connected?(diagnostic) do
      overview = Remote.rpc!(diagnostic.target_node, NixSwarm.API, :cluster_overview, [])
      services = service_names(overview)
      selected_service = normalize_selected_service(selected_service, services)
      selected_node = normalize_selected_node(selected_node, overview)

      service_logs =
        if selected_service do
          Remote.rpc!(diagnostic.target_node, NixSwarm.API, :logs, [selected_service, lines])
        else
          []
        end

      cluster_logs =
        if selected_node && node_live?(overview, selected_node) do
          fetch_cluster_logs(diagnostic.target_node, selected_node, overview, lines)
        else
          ""
        end

      cluster_event_logs = fetch_cluster_event_logs(diagnostic.target_node, overview, lines)

      %{
        diagnostic: diagnostic,
        overview: overview,
        selected_service: selected_service,
        selected_node: selected_node,
        service_logs: service_logs,
        cluster_logs: cluster_logs,
        cluster_event_logs: cluster_event_logs,
        last_refresh_at: timestamp(),
        captured_at_ms: System.monotonic_time(:millisecond)
      }
    else
      %{
        diagnostic: diagnostic,
        overview: nil,
        selected_service: nil,
        selected_node: nil,
        service_logs: [],
        cluster_logs: "",
        cluster_event_logs: "",
        last_refresh_at: timestamp(),
        captured_at_ms: System.monotonic_time(:millisecond)
      }
    end
  end

  defp fetch_cluster_logs(target_node, selected_node, overview, lines) do
    cluster_log_payload(target_node, selected_node, overview, lines)
  end

  defp fetch_cluster_event_logs(target_node, overview, lines) do
    nodes =
      overview
      |> Map.get(:members, %{})
      |> Map.get(:live_nodes, [])
      |> Enum.sort_by(&Atom.to_string/1)

    case nodes do
      [] ->
        "No live nodes are currently connected, so cluster logs are unavailable."

      _ ->
        nodes
        |> Enum.map(fn node ->
          heading = "== #{Atom.to_string(node)} =="
          body = cluster_log_payload(target_node, node, overview, lines) |> String.trim()
          [heading, if(body == "", do: "(no log output)", else: body)] |> Enum.join("\n")
        end)
        |> Enum.join("\n\n")
    end
  end

  defp cluster_log_payload(target_node, selected_node, overview, lines) do
    if Remote.function_exported?(target_node, NixSwarm.API, :cluster_logs, 2) &&
         Remote.function_exported?(selected_node, NixSwarm.API, :local_cluster_logs, 1) do
      Remote.rpc!(target_node, NixSwarm.API, :cluster_logs, [selected_node, lines])
    else
      legacy_cluster_logs(selected_node, overview)
    end
  end

  defp legacy_cluster_logs(selected_node, overview) do
    version =
      overview
      |> node_status_for(selected_node)
      |> case do
        nil -> "unknown"
        node_status -> Map.get(node_status, :version, "unknown")
      end

    [
      "Cluster runtime logs are unavailable from this node's current release.",
      "selected node: #{format_selected_node(selected_node)}",
      "reported version: #{version}",
      "Run the cluster update command, then refresh this view to enable node cluster logs."
    ]
    |> Enum.join("\n")
  end

  defp apply_snapshot(state, snapshot) do
    {new_history, cluster_metrics, metrics_sample} =
      apply_cluster_metrics(
        snapshot,
        state.metrics_history,
        state.cluster_metrics,
        state.metrics_sample
      )

    {node_metric_samples, node_metrics_by_node} =
      apply_node_metrics(snapshot, state.node_metric_samples)

    {service_metric_samples, service_metrics_by_service} =
      apply_service_metrics(snapshot, state.service_metric_samples)

    selected_service =
      normalize_selected_service(
        state.selected_service || snapshot.selected_service,
        service_names(snapshot.overview)
      )

    selected_node =
      normalize_selected_node(state.selected_node || snapshot.selected_node, snapshot.overview)

    service_selection_changed = selected_service != snapshot.selected_service
    node_selection_changed = selected_node != snapshot.selected_node

    pending_machine_actions =
      prune_pending_machine_actions(
        Map.get(state, :pending_machine_actions, %{}),
        snapshot.overview
      )

    %{
      state
      | diagnostic: snapshot.diagnostic,
        overview: snapshot.overview,
        selected_service: selected_service,
        selected_node: selected_node,
        service_logs:
          if(service_selection_changed, do: state.service_logs, else: snapshot.service_logs),
        cluster_logs:
          if(node_selection_changed, do: state.cluster_logs, else: snapshot.cluster_logs),
        cluster_event_logs: snapshot.cluster_event_logs,
        last_refresh_at: snapshot.last_refresh_at,
        last_snapshot_ms: snapshot.captured_at_ms,
        metrics_history: new_history,
        cluster_metrics: cluster_metrics,
        metrics_sample: metrics_sample,
        node_metric_samples: node_metric_samples,
        node_metrics_by_node: node_metrics_by_node,
        service_metric_samples: service_metric_samples,
        service_metrics_by_service: service_metrics_by_service,
        pending_machine_actions: pending_machine_actions
    }
    |> normalize_focused_container()
  end

  defp body_widgets(state, area) do
    [summary_area, content_area] =
      Layout.split(area, :vertical, [
        {:length, 3},
        {:min, 0}
      ])

    widgets =
      [{cluster_issue_widget(state), summary_area}] ++
        case state.active_view do
          :dashboard -> dashboard_widgets(state, content_area)
          :map -> map_widgets(state, content_area)
          :machines -> machines_widgets(state, content_area)
          :services -> services_widgets(state, content_area)
          :logs -> logs_widgets(state, content_area)
        end

    widgets
    |> maybe_rollout_overlay(state, area)
    |> maybe_action_confirmation_overlay(state, area)
    |> maybe_prompt_overlay(state, area)
    |> maybe_help_overlay(state, area)
  end

  defp map_widgets(state, area) do
    content = map_ascii(state)

    [
      {%Paragraph{
         text: pad_lines_to_height(content, area.height),
         wrap: false,
         alignment: :center,
         block: interactive_panel_block(state, :map_canvas, "cluster map [arrows/j/k]")
       }, area}
    ]
  end

  defp map_ascii(%{overview: nil}) do
    [Line.new([Span.new("Waiting for the first refresh.")])]
  end

  defp map_ascii(%{overview: %{status: status}, tick_count: tick_count}) do
    Ascii.cluster_map(status, tick_count)
  end

  defp dashboard_widgets(state, area) do
    [left, right] =
      Layout.split(area, :horizontal, [
        {:percentage, 42},
        {:percentage, 58}
      ])

    [ascii_area, services_area] =
      Layout.split(left, :vertical, [
        {:percentage, 40},
        {:min, 8}
      ])

    [summary_area, rollout_area, detail_area] =
      Layout.split(right, :vertical, [
        {:length, 12},
        {:length, 10},
        {:min, 12}
      ])

    [nodes_table_area, health_area] =
      Layout.split(summary_area, :vertical, [
        {:min, 5},
        {:length, 3}
      ])

    [rollout_summary_area, rollout_table_area] =
      Layout.split(rollout_area, :vertical, [
        {:length, 3},
        {:min, 4}
      ])

    metrics_widgets(state, ascii_area) ++
      [
        {service_table_widget(state), services_area},
        {node_summary_widget(state), nodes_table_area},
        {health_widget(state), health_area},
        {rollout_summary_widget(state), rollout_summary_area},
        {rollout_widget(state), rollout_table_area},
        {service_detail_widget(state), detail_area}
      ]
  end

  defp machines_widgets(state, area) do
    [left, right] =
      Layout.split(area, :horizontal, [
        {:percentage, 42},
        {:percentage, 58}
      ])

    [summary_area, metrics_area, services_area, content_area] =
      Layout.split(right, :vertical, [
        {:length, 12},
        {:length, 10},
        {:length, 9},
        {:min, 10}
      ])

    [context_area, log_area] =
      Layout.split(content_area, :vertical, [
        {:length, 3},
        {:min, 0}
      ])

    [
      {machine_table_widget(state, "machines"), left},
      {%Paragraph{
         text: machine_context_text(state),
         wrap: false,
         scroll: summary_scroll(state),
         block: interactive_panel_block(state, :machines_summary, "machine detail [arrows/hjkl]")
       }, summary_area}
      | metric_grid_widgets(selected_machine_metrics(state), metrics_area, state)
    ] ++
      [
        {doctor_checks_widget(state), services_area},
        {log_context_widget(state, :machines), context_area},
        {content_widget(state, :machines, log_area), log_area}
      ]
  end

  defp services_widgets(state, area) do
    [left, right] =
      Layout.split(area, :horizontal, [
        {:percentage, 28},
        {:percentage, 72}
      ])

    [summary_area, metrics_area, detail_area, content_area] =
      Layout.split(right, :vertical, [
        {:length, 11},
        {:length, 10},
        {:length, 8},
        {:min, 10}
      ])

    [context_area, log_area] =
      Layout.split(content_area, :vertical, [
        {:length, 3},
        {:min, 0}
      ])

    [
      {service_table_widget(state), left},
      {%Paragraph{
         text: selected_service_summary(state),
         wrap: false,
         scroll: summary_scroll(state),
         block: interactive_panel_block(state, :services_summary, "service summary [arrows/hjkl]")
       }, summary_area}
      | metric_grid_widgets(selected_service_metrics(state), metrics_area, state)
    ] ++
      [
        {service_detail_widget(state), detail_area},
        {log_context_widget(state, :services), context_area},
        {content_widget(state, :services, log_area), log_area}
      ]
  end

  defp logs_widgets(state, area) do
    [filter_area, context_area, content_area] =
      Layout.split(area, :vertical, [
        {:length, 3},
        {:length, 3},
        {:min, 0}
      ])

    [
      {log_filter_widget(state), filter_area},
      {log_context_widget(state, :logs), context_area},
      {content_widget(state, :logs, content_area), content_area}
    ]
  end

  defp ensure_viewport(state, {width, height})
       when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    %{state | viewport_width: width, viewport_height: height}
  end

  defp ensure_viewport(state, _test_mode) do
    case ExRatatui.terminal_size() do
      {width, height}
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 ->
        %{state | viewport_width: width, viewport_height: height}

      _ ->
        state
    end
  end

  defp interactive_hit_target(state, x, y) do
    interactive_regions(state)
    |> Enum.find_value(fn region ->
      if point_in_rect?(region.rect, x, y), do: region_target(state, region, x, y)
    end)
  end

  defp interactive_regions(%{viewport_width: width, viewport_height: height} = state)
       when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    area = %Rect{x: 0, y: 0, width: width, height: height}

    [header_area, body_area, _footer_area] =
      Layout.split(area, :vertical, [
        {:length, 3},
        {:min, 0},
        {:length, 3}
      ])

    [tabs_area, _status_area] =
      Layout.split(header_area, :horizontal, [
        {:percentage, 40},
        {:percentage, 60}
      ])

    view_tab_regions(tabs_area) ++ body_interactive_regions(state, body_area)
  end

  defp interactive_regions(_state), do: []

  defp body_interactive_regions(state, area) do
    [_summary_area, content_area] =
      Layout.split(area, :vertical, [
        {:length, 3},
        {:min, 0}
      ])

    case state.active_view do
      :dashboard ->
        [left, _right] =
          Layout.split(content_area, :horizontal, [
            {:percentage, 42},
            {:percentage, 58}
          ])

        [_ascii_area, services_area] =
          Layout.split(left, :vertical, [
            {:percentage, 40},
            {:min, 8}
          ])

        [region(:dashboard_services, services_area, :service_table)]

      :map ->
        [region(:map_canvas, content_area, :container)]

      :machines ->
        [left, right] =
          Layout.split(content_area, :horizontal, [
            {:percentage, 42},
            {:percentage, 58}
          ])

        [summary_area, _metrics_area, _services_area, content_area] =
          Layout.split(right, :vertical, [
            {:length, 12},
            {:length, 10},
            {:length, 9},
            {:min, 10}
          ])

        [_context_area, log_area] =
          Layout.split(content_area, :vertical, [
            {:length, 3},
            {:min, 0}
          ])

        [
          region(:machines_table, left, :machine_table),
          region(:machines_summary, summary_area, :container),
          region(:machines_logs, log_area, :container)
        ]

      :services ->
        [left, right] =
          Layout.split(content_area, :horizontal, [
            {:percentage, 28},
            {:percentage, 72}
          ])

        [summary_area, _metrics_area, _detail_area, content_area] =
          Layout.split(right, :vertical, [
            {:length, 11},
            {:length, 10},
            {:length, 8},
            {:min, 10}
          ])

        [_context_area, log_area] =
          Layout.split(content_area, :vertical, [
            {:length, 3},
            {:min, 0}
          ])

        [
          region(:services_table, left, :service_table),
          region(:services_summary, summary_area, :container),
          region(:services_logs, log_area, :container)
        ]

      :logs ->
        [filter_area, _context_area, content_area] =
          Layout.split(content_area, :vertical, [
            {:length, 3},
            {:length, 3},
            {:min, 0}
          ])

        filter_tab_regions(filter_area) ++ [region(:logs_content, content_area, :container)]
    end
  end

  defp region(id, rect, type), do: %{id: id, rect: rect, type: type}

  defp view_tab_regions(area) do
    tab_regions(area, Enum.map(@views, &String.upcase(to_string(&1))), @views, :view)
  end

  defp filter_tab_regions(area) do
    tab_regions(area, Enum.map(@log_filters, &log_filter_label/1), @log_filters, :log_filter)
  end

  defp tab_regions(area, labels, values, kind) do
    content_x = area.x + 1
    divider = " │ "

    {regions, _cursor} =
      Enum.zip(labels, values)
      |> Enum.reduce({[], content_x}, fn {label, value}, {acc, cursor} ->
        width = String.length(label) + 2
        rect = %Rect{x: cursor, y: area.y + 1, width: width, height: 1}

        target =
          case kind do
            :view -> {:view, value}
            :log_filter -> {:log_filter, value}
          end

        {[%{rect: rect, target: target} | acc], cursor + width + String.length(divider)}
      end)

    Enum.reverse(regions)
  end

  defp point_in_rect?(%Rect{x: x0, y: y0, width: width, height: height}, x, y) do
    x >= x0 and x < x0 + width and y >= y0 and y < y0 + height
  end

  defp region_target(_state, %{target: target}, _x, _y), do: target

  defp region_target(state, %{id: id, rect: rect, type: :service_table}, _x, y) do
    case table_row_index_at(rect, y, length(sorted_service_entries(state))) do
      nil -> {:container, id}
      index -> {:service_row, index}
    end
  end

  defp region_target(state, %{id: id, rect: rect, type: :machine_table}, _x, y) do
    case table_row_index_at(rect, y, length(sorted_machine_entries(state))) do
      nil -> {:container, id}
      index -> {:machine_row, index}
    end
  end

  defp region_target(_state, %{id: id, type: :container}, _x, _y), do: {:container, id}

  defp table_row_index_at(rect, y, row_count) when row_count > 0 do
    index = y - (rect.y + 2)

    if index >= 0 and index < row_count do
      index
    else
      nil
    end
  end

  defp table_row_index_at(_rect, _y, _row_count), do: nil

  defp tabs_widget(state) do
    selected_idx = Enum.find_index(@views, &(&1 == state.active_view)) || 0

    %Tabs{
      titles: Enum.map(@views, &(to_string(&1) |> String.upcase())),
      selected: selected_idx,
      style: %Style{fg: :dark_gray},
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      divider: " │ ",
      block: panel_block("views", :cyan)
    }
  end

  defp status_widget(state) do
    throbber =
      if state.loading do
        %Throbber{
          label: " #{busy_label(state.busy)}",
          step: state.tick_count,
          throbber_set: :braille,
          throbber_style: %Style{fg: :yellow, modifiers: [:bold]},
          style: %Style{fg: :white}
        }
      else
        %Paragraph{text: " idle", style: %Style{fg: :dark_gray}}
      end

    target_text =
      "target: #{state.remote.target} | refreshed: #{state.last_refresh_at || "pending"} | data: #{stale_label(state)}"

    # We return a paragraph but could use a layout. For simplicity, just return the throbber or a paragraph.
    # Actually, let's put it in a block.
    if state.loading do
      %{throbber | block: panel_block(target_text, :dark_gray)}
    else
      %{throbber | block: panel_block(target_text, :dark_gray)}
    end
  end

  defp cluster_issue_widget(state) do
    %Paragraph{
      text: cluster_issue_summary_text(state),
      wrap: true,
      block: panel_block("issues", :yellow)
    }
  end

  defp footer_widget(state) do
    flash_color = if state.last_error, do: :light_red, else: :green
    message = state.last_error || state.flash || "ready"
    message = inline_status_text(message)

    keys =
      cond do
        not is_nil(Map.get(state, :rollout_confirmation)) ->
          [
            Span.new("u/enter", style: %Style{fg: :cyan}),
            Span.new(" confirm rollout | "),
            Span.new("esc", style: %Style{fg: :cyan}),
            Span.new(" cancel")
          ]
          |> maybe_append_rollout_scope_controls(state)
          |> Kernel.++([
            Span.new(" | "),
            Span.new("shift+j/k or J/K", style: %Style{fg: :cyan}),
            Span.new(" scroll")
          ])

        not is_nil(Map.get(state, :action_confirmation)) ->
          [
            Span.new("y/enter", style: %Style{fg: :cyan}),
            Span.new(" confirm machine action | "),
            Span.new("esc/n", style: %Style{fg: :cyan}),
            Span.new(" cancel")
          ]

        true ->
          footer_key_spans(state)
      end

    %Paragraph{
      text: [
        Line.new(keys),
        Line.new([
          Span.new("status: ", style: %Style{fg: :dark_gray}),
          Span.new(message, style: %Style{fg: flash_color, modifiers: [:bold]})
        ])
      ],
      block: %Block{borders: [:top], border_style: %Style{fg: :dark_gray}}
    }
  end

  defp primary_navigation_label(_state), do: "shift+tab focus"

  defp footer_key_spans(state) do
    [
      Span.new("q/esc", style: %Style{fg: :cyan}),
      Span.new(" quit | "),
      Span.new("tab", style: %Style{fg: :cyan}),
      Span.new(" view | "),
      Span.new(primary_navigation_label(state), style: %Style{fg: :cyan}),
      Span.new(" | "),
      Span.new("enter/r", style: %Style{fg: :cyan}),
      Span.new(" refresh | ")
    ]
    |> Kernel.++(footer_action_spans(state))
  end

  defp footer_action_spans(%{active_view: :dashboard} = state) do
    [
      Span.new("c", style: %Style{fg: :cyan}),
      Span.new(" reconcile | "),
      Span.new("u", style: %Style{fg: :cyan}),
      Span.new(" update | "),
      Span.new("P/y", style: %Style{fg: :cyan}),
      Span.new(" apply/dry-run")
    ]
    |> maybe_append_secondary_navigation(state)
  end

  defp footer_action_spans(state) do
    [
      Span.new("c", style: %Style{fg: :cyan}),
      Span.new(" reconcile | "),
      Span.new("u", style: %Style{fg: :cyan}),
      Span.new(" update | "),
      Span.new("P/y", style: %Style{fg: :cyan}),
      Span.new(" apply/dry-run | ")
    ]
    |> maybe_append_secondary_navigation(state)
  end

  defp maybe_append_secondary_navigation(spans, state) do
    label = secondary_navigation_label(state)
    spans ++ [Span.new(" | "), Span.new(label, style: %Style{fg: :cyan})]
  end

  defp maybe_append_rollout_scope_controls(spans, %{rollout_confirmation: confirmation}) do
    if :selected_machine in Map.get(confirmation, :available_scopes, []) do
      spans ++
        [
          Span.new(" | "),
          Span.new("c", style: %Style{fg: :cyan}),
          Span.new(" cluster | "),
          Span.new("m", style: %Style{fg: :cyan}),
          Span.new(" selected machine")
        ]
    else
      spans
    end
  end

  defp maybe_append_rollout_scope_controls(spans, _state), do: spans

  defp secondary_navigation_label(%{active_view: :dashboard}),
    do: "j/k service | o sort | ? help"

  defp secondary_navigation_label(%{active_view: :machines}),
    do: "arrows/hjkl move | R reboot | Z shutdown | / search | t tail | ? help"

  defp secondary_navigation_label(%{active_view: :services}),
    do: "arrows/hjkl move | b start | z stop | x restart | / search | t tail | ? help"

  defp secondary_navigation_label(%{active_view: :logs}),
    do: "arrows/hjkl move | 1-4/f filter | / search | t tail | ? help"

  defp secondary_navigation_label(_state),
    do: "arrows/j/k move | b start | z stop | x restart | ? help"

  defp service_table_widget(%{overview: nil}) do
    %Table{
      header: ["name", "replicas", "owners"],
      rows: [["-", "-", "waiting for the first cluster refresh"]],
      widths: [{:percentage, 32}, {:length, 10}, {:percentage, 58}],
      block: panel_block("services [arrows/j/k | o name↑]")
    }
  end

  defp service_table_widget(state) do
    services = sorted_service_entries(state)

    selected_index =
      if services == [], do: nil, else: selected_service_index(state.selected_service, services)

    rows =
      case services do
        [] ->
          [["-", "0", "no services loaded yet"]]

        _ ->
          Enum.map(services, &service_entry_row/1)
      end

    %Table{
      header: ["name", "replicas", "owners"],
      rows: rows,
      widths: [{:percentage, 32}, {:length, 10}, {:percentage, 58}],
      selected: selected_index,
      highlight_symbol: "> ",
      highlight_style: %Style{fg: :yellow, modifiers: [:bold]},
      block:
        interactive_panel_block(
          state,
          focus_service_container(state),
          "services [arrows/j/k | o #{service_sort_label(state)}]"
        )
    }
  end

  defp machine_table_widget(%{overview: nil}, title) do
    %Table{
      header: ["host name", "node name", "status", "version"],
      rows: [["-", "-", "waiting", "-"]],
      widths: [{:percentage, 22}, {:percentage, 32}, {:length, 14}, {:percentage, 32}],
      block: panel_block("#{title} [arrows/j/k | o host↑]")
    }
  end

  defp machine_table_widget(state, title) do
    nodes = sorted_machine_entries(state)

    selected_index =
      if nodes == [], do: nil, else: selected_node_index(state.selected_node, nodes)

    rows =
      case nodes do
        [] ->
          [["-", "-", "down", "unknown"]]

        _ ->
          Enum.map(nodes, &machine_entry_row/1)
      end

    %Table{
      header: ["host name", "node name", "status", "version"],
      rows: rows,
      widths: [{:percentage, 22}, {:percentage, 32}, {:length, 14}, {:percentage, 32}],
      selected: selected_index,
      highlight_symbol: "> ",
      highlight_style: %Style{fg: :yellow, modifiers: [:bold]},
      block:
        interactive_panel_block(
          state,
          :machines_table,
          "#{title} [arrows/j/k | o #{machine_sort_label(state)}]"
        )
    }
  end

  defp node_summary_widget(%{overview: nil}) do
    %Paragraph{
      text: "Waiting for the first successful refresh.",
      wrap: true,
      block: panel_block("nodes")
    }
  end

  defp node_summary_widget(%{overview: %{members: members, status: status}}) do
    rows =
      status.nodes
      |> Enum.sort_by(fn {node, _status} -> Atom.to_string(node) end)
      |> Enum.map(fn {node, node_status} ->
        {
          owned,
          running
        } =
          node_status.services
          |> Enum.reduce({0, 0}, fn service, {owned_total, running_total} ->
            if service_managed?(service) do
              owned_total = owned_total + length(service.local_owned_slots)
              running_total = running_total + Enum.count(service.units, &(&1.status == :running))
              {owned_total, running_total}
            else
              {owned_total, running_total}
            end
          end)

        version = node_version_cell(%{members: members, status: status}, node, node_status)
        uptime = node_status |> Map.get(:metrics, %{}) |> Map.get(:uptime, 0) |> format_duration()

        [
          Atom.to_string(node),
          if(node in members.live_nodes,
            do: Span.new("up", style: %Style{fg: :green, modifiers: [:bold]}),
            else: Span.new("down", style: %Style{fg: :red, modifiers: [:bold]})
          ),
          version,
          uptime,
          Integer.to_string(owned),
          Integer.to_string(running)
        ]
      end)

    %Table{
      header: ["node", "live", "version", "uptime", "owned", "running"],
      rows: rows,
      widths: [
        {:percentage, 24},
        {:length, 8},
        {:percentage, 22},
        {:length, 10},
        {:length, 8},
        {:length, 9}
      ],
      block: panel_block("nodes")
    }
  end

  defp health_widget(%{overview: nil}) do
    %Gauge{
      ratio: 0.0,
      label: "loading...",
      gauge_style: %Style{fg: :dark_gray},
      block: panel_block("health")
    }
  end

  defp health_widget(%{overview: %{status: status}}) do
    {total_running, total_owned} =
      status.nodes
      |> Enum.reduce({0, 0}, fn {_node, node_status}, {running, owned} ->
        node_status.services
        |> Enum.reduce({running, owned}, fn service, {r, o} ->
          if service_managed?(service) do
            o_service = length(service.local_owned_slots)
            r_service = Enum.count(service.units, &(&1.status == :running))
            {r + r_service, o + o_service}
          else
            {r, o}
          end
        end)
      end)

    ratio = if total_owned > 0, do: min(total_running / total_owned, 1.0), else: 0.0
    label = "#{total_running}/#{total_owned} running (#{round(ratio * 100)}%)"

    color =
      cond do
        total_owned == 0 -> :dark_gray
        total_running >= total_owned and total_owned > 0 -> :green
        ratio > 0.5 -> :yellow
        true -> :red
      end

    %Gauge{
      ratio: ratio,
      label: label,
      gauge_style: %Style{fg: color},
      block: panel_block("cluster health")
    }
  end

  defp service_detail_widget(%{overview: nil}) do
    %Paragraph{
      text: "No cluster overview is available yet.",
      wrap: true,
      block: panel_block("service detail")
    }
  end

  defp service_detail_widget(state) do
    service = state.selected_service
    slots = selected_slots(state.overview, service)

    rows =
      if slots == [] do
        [["-", "-", "-", "-"]]
      else
        Enum.map(slots, fn slot ->
          status = slot_running_status(state.overview, slot.owner, service, slot.unit)

          [
            Integer.to_string(slot.slot),
            Atom.to_string(slot.owner),
            slot.unit,
            unit_status_span(status)
          ]
        end)
      end

    %Table{
      header: ["slot", "owner", "unit", "status"],
      rows: rows,
      widths: [{:length, 6}, {:percentage, 34}, {:percentage, 34}, {:length, 14}],
      block: panel_block("service detail#{if(service, do: " #{service}", else: "")}")
    }
  end

  defp doctor_checks_widget(%{overview: nil}) do
    %Table{
      header: ["service", "state", "owned", "running", "units"],
      rows: [["-", "-", "-", "-", "waiting for the first cluster refresh"]],
      widths: [{:percentage, 20}, {:length, 12}, {:length, 8}, {:length, 9}, {:percentage, 51}],
      block: panel_block("machine services")
    }
  end

  defp doctor_checks_widget(state) do
    rows =
      case selected_node_services(state) do
        [] ->
          [["-", "-", "-", "-", "no services are currently placed on this node"]]

        services ->
          Enum.map(services, fn service ->
            running = Enum.count(service.units, &(&1.status == :running))

            [
              service.name,
              service_status_label(state.overview, service.name),
              Integer.to_string(length(service.local_owned_slots)),
              Integer.to_string(running),
              Enum.map_join(service.units, ", ", & &1.unit)
            ]
          end)
      end

    %Table{
      header: ["service", "state", "owned", "running", "units"],
      rows: rows,
      widths: [{:percentage, 20}, {:length, 12}, {:length, 8}, {:length, 9}, {:percentage, 51}],
      block: panel_block("machine services")
    }
  end

  defp machine_context_text(%{overview: nil}) do
    "No cluster overview is available yet."
  end

  defp machine_context_text(state) do
    node = state.selected_node
    node_status = selected_node_status(state)
    network_info = Map.get(node_status || %{}, :network_info, %{})
    version = if node_status, do: Map.get(node_status, :version, "unknown"), else: "unknown"
    update_status = selected_node_update_status(state.overview, node)

    uptime =
      Map.get(node_status || %{}, :metrics, %{}) |> Map.get(:uptime, 0) |> format_duration()

    [
      "node: #{format_selected_node(node)}",
      "status: #{machine_status_label(state, state.overview, node, node_status)}",
      "live: #{if(node_live?(state.overview, node), do: "yes", else: "no")}",
      "version: #{version}",
      "update available: #{update_status}",
      "uptime: #{uptime}",
      "deploy host: #{selected_node_deploy_host(state) || "-"}",
      "query target: #{state.remote.target}",
      "source: #{state.config_paths.source}",
      "machine file: #{current_selected_file(state, :machines) || "(no matching file)"}",
      "cluster file: #{ConfigFiles.cluster_file(state.config_paths)}",
      "remote path: #{state.config_paths.remote_path}",
      "nixos dir: #{state.config_paths.nixos_dir}",
      "ips: #{format_list(Map.get(network_info, :ips, []))}",
      "ports: #{format_port_list(Map.get(network_info, :ports, []))}"
    ]
    |> Enum.join("\n")
  end

  defp cluster_log_text(%{selected_node: nil}) do
    "Select a node to inspect its cluster logs."
  end

  defp cluster_log_text(%{overview: overview, selected_node: node, cluster_logs: cluster_logs}) do
    cluster_logs = ClusterLogs.sanitize(cluster_logs) |> String.trim()

    cond do
      not node_live?(overview, node) ->
        "The selected node is not live, so cluster logs are unavailable."

      cluster_logs == "" ->
        "No cluster log data is available for the selected node."

      true ->
        cluster_logs
    end
  end

  defp selected_service_summary(%{overview: nil}) do
    "No service data is loaded yet."
  end

  defp selected_service_summary(%{selected_service: nil}) do
    "No service is currently selected."
  end

  defp selected_service_summary(state) do
    service = state.selected_service
    slots = selected_slots(state.overview, service)
    owners = slots |> Enum.map(& &1.owner) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    running =
      Enum.count(slots, fn slot ->
        slot_running_status(state.overview, slot.owner, service, slot.unit) == "running"
      end)

    [
      "service: #{service}",
      "status: #{service_status_label(state.overview, service)}",
      "replicas: #{length(slots)}",
      "owners: #{if(owners == [], do: "-", else: Enum.map_join(owners, ", ", &Atom.to_string/1))}",
      "running units: #{running}/#{length(slots)}",
      "source: #{state.config_paths.source}",
      "service file: #{current_selected_file(state, :services) || "(no matching file)"}",
      "cluster file: #{ConfigFiles.cluster_file(state.config_paths)}",
      "services dir: #{state.config_paths.services_dir}",
      "remote path: #{state.config_paths.remote_path}",
      "nixos dir: #{state.config_paths.nixos_dir}"
    ]
    |> Enum.join("\n")
  end

  defp cluster_event_log_text(state) do
    case Map.get(state, :cluster_event_logs, "") |> ClusterLogs.sanitize() |> String.trim() do
      "" -> "No cluster log data is available yet."
      output -> output
    end
  end

  defp logs_page_text(state) do
    case current_log_filter(state) do
      :all -> cluster_event_log_text(state)
      :errors -> cluster_error_log_text(state)
      :selected_machine -> cluster_log_text(state)
      :selected_service -> log_text(state)
    end
  end

  defp log_filter_widget(state) do
    selected = Enum.find_index(@log_filters, &(&1 == current_log_filter(state))) || 0

    %Tabs{
      titles: Enum.map(@log_filters, &log_filter_label/1),
      selected: selected,
      style: %Style{fg: :dark_gray},
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      divider: " │ ",
      block: interactive_panel_block(state, :logs_filter, "log filter [1-4/f]", :cyan)
    }
  end

  defp content_widget(state, view, area) do
    {title, text} = content_panel(state, view)

    %Paragraph{
      text: text,
      wrap: false,
      scroll: resolved_content_scroll(state, text, area),
      block: interactive_panel_block(state, content_container(view), title)
    }
  end

  defp content_panel(state, view) do
    case view do
      :machines -> {"machine logs [arrows/hjkl]", cluster_log_text(state)}
      :services -> {"service logs [arrows/hjkl]", log_text(state)}
      :logs -> {"cluster logs [arrows/hjkl]", logs_page_text(state)}
    end
  end

  defp log_context_widget(state, view) do
    %Paragraph{
      text: log_context_text(state, view),
      wrap: true,
      block: panel_block("log context", :cyan)
    }
  end

  defp log_text(%{selected_service: nil}) do
    "Select a service to inspect its logs."
  end

  defp log_text(%{overview: overview, selected_service: service, service_logs: logs}) do
    cond do
      logs == [] ->
        "No log data is available for #{service}."

      true ->
        logs
        |> Enum.flat_map(fn {node, units} ->
          [
            "== #{Atom.to_string(node)} ==",
            Enum.map_join(units, "\n\n", fn unit ->
              status = slot_running_status(overview, node, service, unit.unit)

              """
              -- slot #{unit.slot} #{unit.unit} (#{status}) --
              #{String.trim(unit.logs)}
              """
              |> String.trim()
            end)
          ]
        end)
        |> Enum.join("\n\n")
        |> String.trim()
    end
  end

  defp cluster_error_log_text(state) do
    raw_logs = Map.get(state, :cluster_event_logs, "") |> ClusterLogs.sanitize() |> String.trim()

    cond do
      raw_logs == "" ->
        "No cluster log data is available yet."

      true ->
        raw_logs
        |> split_log_sections()
        |> Enum.flat_map(fn {heading, lines} ->
          matches = Enum.filter(lines, &error_log_line?/1)

          case {heading, matches} do
            {_heading, []} -> []
            {nil, matches} -> [Enum.join(matches, "\n")]
            {heading, matches} -> [heading, Enum.join(matches, "\n")]
          end
        end)
        |> Enum.join("\n\n")
        |> case do
          "" -> "No error or warning lines matched the current cluster logs."
          output -> output
        end
    end
  end

  defp split_log_sections(output) do
    output
    |> String.split("\n")
    |> Enum.reduce({nil, [], []}, fn line, {heading, lines, sections} ->
      if log_section_heading?(line) do
        sections =
          case {heading, Enum.reject(lines, &(&1 == ""))} do
            {nil, []} -> sections
            {current_heading, current_lines} -> sections ++ [{current_heading, current_lines}]
          end

        {line, [], sections}
      else
        {heading, lines ++ [line], sections}
      end
    end)
    |> then(fn {heading, lines, sections} ->
      case {heading, Enum.reject(lines, &(&1 == ""))} do
        {nil, []} -> sections
        {current_heading, current_lines} -> sections ++ [{current_heading, current_lines}]
      end
    end)
  end

  defp log_section_heading?(line) do
    String.starts_with?(line, "== ") and String.ends_with?(line, " ==")
  end

  defp error_log_line?(line) do
    lowered = String.downcase(line)

    Enum.any?(
      [
        "error",
        "warn",
        "failed",
        "failure",
        "exception",
        "critical",
        "panic",
        "timeout",
        "sigterm",
        "nodedown",
        "port_died"
      ],
      &String.contains?(lowered, &1)
    )
  end

  defp current_log_text(state) do
    case state.active_view do
      :machines -> cluster_log_text(state)
      :services -> log_text(state)
      :logs -> logs_page_text(state)
      _view -> logs_page_text(state)
    end
  end

  defp log_context_text(state, :machines) do
    [
      "machine: #{format_selected_node(Map.get(state, :selected_node))}",
      "status: #{selected_node_status_label(state)}",
      "tail: #{tail_label(state)}",
      search_status_label(state),
      "C/E logs",
      "Y/U row"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
  end

  defp log_context_text(state, :services) do
    [
      "service: #{Map.get(state, :selected_service) || "-"}",
      "status: #{selected_service_status_label(state)}",
      "owners: #{selected_service_owner_summary(state)}",
      "tail: #{tail_label(state)}",
      search_status_label(state),
      "C/E logs",
      "Y/U row"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
  end

  defp log_context_text(state, :logs) do
    [
      "filter: #{String.downcase(log_filter_label(current_log_filter(state)))}",
      "machine: #{format_selected_node(Map.get(state, :selected_node))}",
      "service: #{Map.get(state, :selected_service) || "-"}",
      "tail: #{tail_label(state)}",
      search_status_label(state),
      "C/E logs"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
  end

  defp selected_node_status_label(%{overview: overview, selected_node: node} = state) do
    machine_status_label(state, overview, node, node_status_for(overview, node))
  end

  defp selected_node_status_label(_state), do: "down"

  defp selected_service_owner_summary(%{overview: nil}), do: "-"

  defp selected_service_owner_summary(%{overview: overview} = state) do
    overview
    |> selected_slots(Map.get(state, :selected_service))
    |> service_owner_hostnames(overview)
    |> format_list()
  end

  defp selected_service_owner_summary(_state), do: "-"

  defp tail_label(state) do
    if Map.get(state, :log_tail?, true), do: "on", else: "off"
  end

  defp search_status_label(state) do
    query = Map.get(state, :log_search_query)

    if is_nil(query) do
      nil
    else
      matches = log_search_match_lines(state)

      if matches == [] do
        "search: #{query} (0)"
      else
        current = rem(Map.get(state, :log_search_match_index, 0), length(matches)) + 1
        "search: #{query} (#{current}/#{length(matches)})"
      end
    end
  end

  defp cluster_issue_summary_text(%{overview: nil}) do
    "waiting for cluster health data"
  end

  defp cluster_issue_summary_text(state) do
    log_errors =
      state
      |> Map.get(:cluster_event_logs, "")
      |> ClusterLogs.sanitize()
      |> String.split("\n")
      |> Enum.count(&error_log_line?/1)

    machine_issues =
      state
      |> machine_entries()
      |> Enum.count(&(&1.status != "up"))

    service_issues =
      state
      |> service_entries()
      |> Enum.count(&service_issue?(state.overview, &1))

    "machines with issues: #{machine_issues} | services with issues: #{service_issues} | warning/error log lines: #{log_errors}"
  end

  defp service_issue?(overview, entry) do
    service_status = service_status_label(overview, entry.name)
    service_status not in ["running", "stopped"]
  end

  defp machine_issue_count(node, node_status) do
    node_status
    |> Map.get(:services, [])
    |> Enum.reduce(0, fn service, total ->
      if service_managed?(service) do
        total +
          Enum.count(service.units, fn unit ->
            Map.get(unit, :owner) == node and unit.status != :running
          end)
      else
        total
      end
    end)
  end

  defp build_log_action(state, action) do
    label = log_export_label(state)
    text = current_log_text(state)

    if String.trim(text) == "" do
      {:error, put_error(state, "no log content is available to #{action}")}
    else
      {:ok, %{state | pending_action: external_action(action, label, text)}}
    end
  end

  defp build_selection_action(state, action) do
    case current_selection_export(state) do
      nil ->
        {:error, put_error(state, "no table selection is available to #{action}")}

      {label, text} ->
        {:ok, %{state | pending_action: external_action(action, label, text)}}
    end
  end

  defp external_action(:copy, label, text), do: {:copy_text, label, text}
  defp external_action(:export, label, text), do: {:export_text, label, text}
  defp external_action(:edit, _label, path), do: {:edit_file, path}

  defp external_action_transition({:ok, state}) do
    {:stop, note_input(state)}
  end

  defp external_action_transition({:error, state}) do
    {:noreply, note_input(state)}
  end

  defp log_export_label(%{active_view: :machines, selected_node: node}),
    do: "machine-logs-#{node_slug(node)}"

  defp log_export_label(%{active_view: :services, selected_service: service}),
    do: "service-logs-#{service || "selection"}"

  defp log_export_label(state), do: "cluster-logs-#{current_log_filter(state)}"

  defp current_selection_export(%{active_view: :machines} = state) do
    entry = Enum.find(machine_entries(state), &(&1.node == state.selected_node))

    if entry do
      {"machine-row-#{node_slug(entry.node)}",
       Enum.join(["host name\tnode name\tstatus\tversion", machine_selection_line(entry)], "\n")}
    end
  end

  defp current_selection_export(state) do
    entry = Enum.find(service_entries(state), &(&1.name == state.selected_service))

    if entry do
      {"service-row-#{entry.name}",
       Enum.join(["name\treplicas\towners", service_selection_line(entry)], "\n")}
    end
  end

  defp machine_selection_line(entry) do
    Enum.join([entry.host_name, entry.node_name, entry.status, entry.version], "\t")
  end

  defp service_selection_line(entry) do
    Enum.join(
      [entry.name, Integer.to_string(entry.replicas), Enum.join(entry.owners, ", ")],
      "\t"
    )
  end

  defp node_slug(nil), do: "selection"
  defp node_slug(node), do: node |> Atom.to_string() |> String.replace(~r/[^A-Za-z0-9]+/, "-")

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp text_line_count(text) do
    text
    |> to_string()
    |> String.split("\n", trim: false)
    |> length()
  end

  defp metrics_widgets(state, area) do
    metric_stack_widgets(Map.get(state, :cluster_metrics, default_cluster_metrics()), area, state)
  end

  defp metric_grid_widgets(metrics, area, state, variant \\ :gauge) do
    [top, bottom] =
      Layout.split(area, :vertical, [
        {:percentage, 50},
        {:percentage, 50}
      ])

    [cpu_area, memory_area] =
      Layout.split(top, :horizontal, [
        {:percentage, 50},
        {:percentage, 50}
      ])

    [disk_area, network_area] =
      Layout.split(bottom, :horizontal, [
        {:percentage, 50},
        {:percentage, 50}
      ])

    [
      {metric_widget("cpu", metrics.cpu, :cyan, state, variant), cpu_area},
      {metric_widget("memory", metrics.memory, :magenta, state, variant), memory_area},
      {metric_widget("disk", metrics.disk, :yellow, state, variant), disk_area},
      {metric_widget("network", metrics.network, :green, state, variant), network_area}
    ]
  end

  defp metric_stack_widgets(metrics, area, state, variant \\ :gauge) do
    [cpu_area, memory_area, disk_area, network_area] =
      Layout.split(area, :vertical, [
        {:percentage, 25},
        {:percentage, 25},
        {:percentage, 25},
        {:percentage, 25}
      ])

    [
      {metric_widget("cpu", metrics.cpu, :cyan, state, variant), cpu_area},
      {metric_widget("memory", metrics.memory, :magenta, state, variant), memory_area},
      {metric_widget("disk", metrics.disk, :yellow, state, variant), disk_area},
      {metric_widget("network", metrics.network, :green, state, variant), network_area}
    ]
  end

  defp metric_widget(name, metric, color, state, :card) do
    metric_card_widget(name, metric, color, state)
  end

  defp metric_widget(name, metric, color, state, _variant) do
    metric_gauge_widget(name, metric, color, state)
  end

  defp metric_card_widget(name, metric, color, state) do
    pct = visible_metric_pct(metric)

    %Paragraph{
      text: [
        Line.new([
          Span.new(metric.label, style: %Style{fg: :white, modifiers: [:bold]})
        ]),
        Line.new([
          Span.new(metric_progress_bar(metric), style: %Style{fg: color, modifiers: [:bold]}),
          Span.new("  "),
          Span.new("#{format_decimal(pct)}%", style: %Style{fg: color, modifiers: [:bold]})
        ]),
        Line.new([
          Span.new(metric_card_caption(name), style: %Style{fg: :dark_gray})
        ])
      ],
      wrap: true,
      block: panel_block(metric_panel_title(name, nil, state))
    }
  end

  defp metric_gauge_widget(name, metric, color, state) do
    label = "#{metric.label} (#{format_decimal(visible_metric_pct(metric))}%)"

    %Gauge{
      ratio: visible_metric_ratio(metric),
      label: label,
      gauge_style: %Style{fg: color},
      block: panel_block(metric_panel_title(name, nil, state))
    }
  end

  defp visible_metric_ratio(metric) do
    ratio = clamp_ratio(visible_metric_pct(metric) / 100)

    cond do
      ratio > 0 and ratio < 0.01 -> 0.01
      positive_metric_usage?(metric) and ratio == 0.0 -> 0.01
      true -> ratio
    end
  end

  defp visible_metric_pct(metric) do
    pct = Map.get(metric, :pct, 0)

    cond do
      pct > 0 -> pct
      positive_metric_usage?(metric) -> 0.1
      true -> 0.0
    end
  end

  defp positive_metric_usage?(metric) do
    Map.get(metric, :used, 0) > 0 and Map.get(metric, :total, 0) > 0
  end

  defp metric_progress_bar(metric, segments \\ 18) do
    filled =
      visible_metric_ratio(metric)
      |> Kernel.*(segments)
      |> round()
      |> max(0)
      |> min(segments)

    "[" <> String.duplicate("█", filled) <> String.duplicate("·", segments - filled) <> "]"
  end

  defp metric_card_caption("network"), do: "cluster throughput / capacity"
  defp metric_card_caption(_name), do: "cluster used / total"

  defp clamp_ratio(value) when is_number(value) do
    value
    |> max(0.0)
    |> min(1.0)
    |> :erlang.float()
  end

  defp clamp_ratio(_), do: 0.0

  defp rollout_summary_widget(%{last_rollout: nil, overview: overview}) do
    %Paragraph{
      text:
        "Last successful update: none yet\nUpdate available: #{cluster_update_status(overview)}",
      wrap: true,
      block: panel_block("rollout summary")
    }
  end

  defp rollout_summary_widget(%{last_rollout: rollout, overview: overview}) do
    target_hosts = Map.get(rollout, :target_hosts, [])
    version = version_summary(Map.get(rollout, :after_versions, %{}))

    %Paragraph{
      text:
        "Last successful update: #{Map.get(rollout, :completed_at, "-")}\nVersion: #{version}\nTargets: #{if(target_hosts == [], do: "-", else: Enum.join(target_hosts, ", "))}\nUpdate available: #{cluster_update_status(overview)}",
      wrap: true,
      block: panel_block("rollout summary")
    }
  end

  defp rollout_widget(%{last_rollout: nil}) do
    %Paragraph{
      text:
        "No rollout has run yet.\nPress u to preview target hosts before applying the next update.",
      wrap: true,
      block: panel_block("rollout status")
    }
  end

  defp rollout_widget(%{last_rollout: rollout}) do
    after_versions = Map.get(rollout, :after_versions, %{})
    before_versions = Map.get(rollout, :before_versions, %{})

    rows =
      after_versions
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn node ->
        before_version = Map.get(before_versions, node, "-")
        after_version = Map.get(after_versions, node, "-")

        [
          node,
          before_version,
          after_version,
          if(before_version == after_version, do: "steady", else: "updated")
        ]
      end)
      |> case do
        [] -> [["-", "-", "-", "no live version data"]]
        entries -> entries
      end

    %Table{
      header: ["node", "before", "after", "result"],
      rows: rows,
      widths: [{:percentage, 28}, {:percentage, 26}, {:percentage, 26}, {:percentage, 20}],
      block: panel_block("rollout status")
    }
  end

  defp selected_slots(nil, _service), do: []
  defp selected_slots(_overview, nil), do: []

  defp selected_slots(%{status: %{placements: placements}}, service),
    do: Map.get(placements, service, [])

  defp slot_running_status(%{status: %{nodes: nodes}}, owner, service, unit) do
    nodes
    |> Enum.find_value("unknown", fn {node, node_status} ->
      if node == owner do
        node_status.services
        |> Enum.find(fn node_service -> node_service.name == service end)
        |> case do
          nil ->
            nil

          service_status ->
            case Enum.find(service_status.units, fn unit_status -> unit_status.unit == unit end) do
              %{status: status} -> Atom.to_string(status)
              nil -> "unknown"
            end
        end
      end
    end)
  end

  defp move_primary_selection(%{active_view: view} = state, delta)
       when view == :machines do
    move_node_selection(state, delta)
  end

  defp move_primary_selection(state, delta), do: move_service_selection(state, delta)

  defp move_service_selection(state, delta) do
    services = sorted_service_entries(state)

    case services do
      [] ->
        state

      _ ->
        current_index = selected_service_index(state.selected_service, services)
        new_index = clamp(current_index + delta, 0, length(services) - 1)
        selected_service = services |> Enum.at(new_index) |> Map.get(:name)

        new_state =
          state
          |> Map.put(:selected_service, selected_service)
          |> reset_content_scroll()

        if selected_service == state.selected_service do
          new_state
        else
          request_refresh(new_state, :selection)
        end
    end
  end

  defp move_node_selection(state, delta) do
    nodes = sorted_machine_entries(state)

    case nodes do
      [] ->
        state

      _ ->
        current_index = selected_node_index(state.selected_node, nodes)
        new_index = clamp(current_index + delta, 0, length(nodes) - 1)
        selected_node = nodes |> Enum.at(new_index) |> Map.get(:node)

        new_state =
          state
          |> Map.put(:selected_node, selected_node)
          |> reset_content_scroll()

        if selected_node == state.selected_node do
          new_state
        else
          request_refresh(new_state, :node_selection)
        end
    end
  end

  defp service_entries(%{overview: nil}), do: []

  defp service_entries(state) do
    Enum.map(service_names(state.overview), fn service ->
      slots = selected_slots(state.overview, service)

      %{
        name: service,
        replicas: length(slots),
        owners: service_owner_hostnames(slots, state.overview)
      }
    end)
  end

  defp sorted_service_entries(state) do
    {field, direction} = Map.get(state, :service_sort, {:name, :asc})

    Enum.sort_by(service_entries(state), &service_sort_value(&1, field), direction)
  end

  defp service_sort_value(entry, :replicas), do: entry.replicas
  defp service_sort_value(entry, :owners), do: Enum.join(entry.owners, ",")
  defp service_sort_value(entry, _field), do: String.downcase(entry.name)

  defp service_entry_row(entry) do
    [entry.name, Integer.to_string(entry.replicas), format_list(entry.owners)]
  end

  defp selected_service_status_label(%{overview: overview, selected_service: service}),
    do: service_status_label(overview, service)

  defp selected_service_status_label(_state), do: "unknown"

  defp service_status_label(nil, _service), do: "unknown"
  defp service_status_label(_overview, nil), do: "unknown"

  defp service_status_label(overview, service) do
    desired_state = service_desired_state(overview, service)

    statuses =
      overview
      |> selected_slots(service)
      |> Enum.map(fn slot ->
        slot_running_status(overview, slot.owner, service, slot.unit)
      end)

    cond do
      desired_state == :stopped and Enum.any?(statuses, &(&1 not in ["stopped", "unknown"])) ->
        "stopping"

      desired_state == :stopped ->
        "stopped"

      Enum.any?(statuses, &(&1 == "restarting")) ->
        "restarting"

      Enum.any?(statuses, &(&1 == "starting")) ->
        "starting"

      Enum.any?(statuses, &(&1 == "stopping")) ->
        "stopping"

      Enum.any?(statuses, &(&1 == "failed")) ->
        "failed"

      statuses == [] ->
        "unknown"

      Enum.all?(statuses, &(&1 == "running")) ->
        "running"

      Enum.any?(statuses, &(&1 == "running")) ->
        "degraded"

      Enum.all?(statuses, &(&1 == "stopped")) ->
        "stopped"

      true ->
        "unknown"
    end
  end

  defp service_sort_label(state) do
    state
    |> Map.get(:service_sort, {:name, :asc})
    |> sort_label()
  end

  defp machine_entries(%{overview: nil}), do: []

  defp machine_entries(state) do
    Enum.map(cluster_node_names(state.overview), fn node ->
      node_status = node_status_for(state.overview, node)
      status = machine_status_label(state, state.overview, node, node_status)

      %{
        node: node,
        host_name: node_hostname(state.overview, node),
        node_name: Atom.to_string(node),
        status: status,
        version: if(node_status, do: Map.get(node_status, :version, "unknown"), else: "unknown"),
        update_available?: node_update_available?(state.overview, node)
      }
    end)
  end

  defp sorted_machine_entries(state) do
    {field, direction} = Map.get(state, :machine_sort, {:host, :asc})

    Enum.sort_by(machine_entries(state), &machine_sort_value(&1, field), direction)
  end

  defp machine_sort_value(entry, :status), do: machine_status_rank(entry.status)
  defp machine_sort_value(entry, :version), do: String.downcase(entry.version)
  defp machine_sort_value(entry, _field), do: String.downcase(entry.host_name)

  defp machine_status_rank("up"), do: 0
  defp machine_status_rank("restarting"), do: 1
  defp machine_status_rank("shutting down"), do: 2
  defp machine_status_rank("degraded"), do: 3
  defp machine_status_rank(_status), do: 4

  defp machine_entry_row(entry) do
    [
      entry.host_name,
      entry.node_name,
      live_status_span(entry.status),
      machine_version_span(entry)
    ]
  end

  defp machine_sort_label(state) do
    state
    |> Map.get(:machine_sort, {:host, :asc})
    |> sort_label()
  end

  defp sort_label({field, direction}) do
    "#{field}#{if(direction == :asc, do: "↑", else: "↓")}"
  end

  defp service_names(nil), do: []

  defp service_names(%{status: %{placements: placements}}) do
    placements
    |> Map.keys()
    |> Enum.sort()
  end

  defp cluster_node_names(nil), do: []

  defp cluster_node_names(%{members: members, status: status}) do
    (Map.get(members, :configured_nodes, []) ++
       Map.get(members, :live_nodes, []) ++ Enum.map(Map.get(status, :nodes, []), &elem(&1, 0)))
    |> Enum.uniq()
    |> Enum.sort_by(&Atom.to_string/1)
  end

  defp normalize_selected_node(selected_node, overview) do
    nodes = cluster_node_names(overview)

    cond do
      selected_node in nodes ->
        selected_node

      overview.members.queried_node in nodes ->
        overview.members.queried_node

      nodes == [] ->
        nil

      true ->
        hd(nodes)
    end
  end

  defp selected_node_index(nil, _nodes), do: 0

  defp selected_node_index(selected_node, nodes) do
    Enum.find_index(nodes, fn
      %{node: node} -> node == selected_node
      node -> node == selected_node
    end) || 0
  end

  defp node_status_for(nil, _node), do: nil

  defp node_status_for(%{status: %{nodes: nodes}}, node) do
    Enum.find_value(nodes, fn
      {^node, node_status} -> node_status
      _ -> nil
    end)
  end

  defp selected_node_status(%{overview: overview, selected_node: selected_node}) do
    node_status_for(overview, selected_node)
  end

  defp current_selected_file(state, :machines) do
    ConfigFiles.machine_file_for_node(state.config_paths, state.selected_node)
  end

  defp current_selected_file(state, :services) do
    if state.selected_service do
      ConfigFiles.service_file_for_name(state.config_paths, state.selected_service)
    end
  end

  defp open_add_config_prompt(state, :machines) do
    %{
      state
      | prompt: %{
          kind: :add_machine,
          title: "add machine",
          label: "nodeName deployHost labels(comma-separated)",
          value: ""
        }
    }
    |> put_flash("enter machine as: nix-swarm@host root@host label1,label2")
  end

  defp open_add_config_prompt(state, :services) do
    %{
      state
      | prompt: %{
          kind: :add_service,
          title: "add service",
          label:
            "name replicas constraints(comma-separated) preferredNodes(comma-separated, optional)",
          value: ""
        }
    }
    |> put_flash("enter service as: name 1 label1,label2 nix-swarm@host")
  end

  defp edit_selected_config_file(state, view) do
    case current_selected_file(state, view) do
      nil ->
        {:error, put_error(state, "no #{config_view_label(view)} file is selected")}

      path ->
        {:ok,
         %{
           state
           | pending_action: external_action(:edit, "#{config_view_label(view)}-file", path)
         }}
    end
  end

  defp delete_selected_config(state, :machines) do
    case current_selected_file(state, :machines) do
      nil ->
        put_error(state, "no machine file is selected")

      path ->
        case ConfigFiles.delete_machine(state.config_paths, path) do
          {:ok, _path, warnings} -> put_flash(state, delete_message("machine", warnings))
          {:error, message} -> put_error(state, message)
        end
    end
  end

  defp delete_selected_config(%{selected_service: nil} = state, :services) do
    put_error(state, "no service is selected")
  end

  defp delete_selected_config(state, :services) do
    case ConfigFiles.delete_service(state.config_paths, state.selected_service) do
      {:ok, _path, warnings} -> put_flash(state, delete_message("service", warnings))
      {:error, message} -> put_error(state, message)
    end
  end

  defp parse_add_machine_input(value) do
    case String.split(value, ~r/\s+/, parts: 3, trim: true) do
      [node_name, deploy_host, labels] -> {:ok, node_name, deploy_host, split_csv(labels)}
      [node_name, deploy_host] -> {:ok, node_name, deploy_host, []}
      _ -> {:error, "machine input must be: nodeName deployHost labels"}
    end
  end

  defp parse_add_service_input(value) do
    case String.split(value, ~r/\s+/, parts: 4, trim: true) do
      [name, replicas, constraints, preferred_nodes] ->
        with {:ok, replicas} <- parse_non_negative_integer(replicas) do
          {:ok, name, replicas, split_csv(constraints), split_csv(preferred_nodes)}
        end

      [name, replicas, constraints] ->
        with {:ok, replicas} <- parse_non_negative_integer(replicas) do
          {:ok, name, replicas, split_csv(constraints), []}
        end

      _ ->
        {:error, "service input must be: name replicas constraints [preferredNodes]"}
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> {:error, "replicas must be zero or greater"}
    end
  end

  defp split_csv("-"), do: []

  defp split_csv(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp config_view_label(:machines), do: "machine"
  defp config_view_label(:services), do: "service"

  defp delete_message(kind, []), do: "#{kind} deleted"
  defp delete_message(kind, warnings), do: "#{kind} deleted; #{Enum.join(warnings, "; ")}"

  defp selected_node_services(state) do
    state
    |> selected_node_status()
    |> case do
      nil -> []
      node_status -> Map.get(node_status, :services, [])
    end
  end

  defp selected_node_deploy_host(%{overview: nil}), do: nil

  defp selected_node_deploy_host(%{overview: %{members: members}, selected_node: selected_node}) do
    deploy_host_for_node(Map.get(members, :deploy_hosts, %{}), selected_node)
  end

  defp deploy_host_for_node(deploy_hosts, node) when is_atom(node) do
    Map.get(deploy_hosts, node) || Map.get(deploy_hosts, Atom.to_string(node))
  end

  defp deploy_host_for_node(deploy_hosts, node_name) when is_binary(node_name) do
    Map.get(deploy_hosts, node_name) ||
      Enum.find_value(deploy_hosts, fn {configured_node, deploy_host} ->
        if Atom.to_string(configured_node) == node_name, do: deploy_host
      end)
  end

  defp deploy_host_for_node(_deploy_hosts, _node), do: nil

  defp service_owner_hostnames(slots, overview) do
    slots
    |> Enum.map(&Map.get(&1, :owner))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&node_hostname(overview, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp service_desired_state(nil, _service), do: :running

  defp service_desired_state(%{status: %{nodes: nodes}}, service) do
    Enum.find_value(nodes, :running, fn {_node, node_status} ->
      node_status.services
      |> Enum.find(fn node_service -> node_service.name == service end)
      |> case do
        %{desired_state: desired_state} -> desired_state
        _ -> nil
      end
    end)
  end

  defp service_managed?(service) do
    Map.get(service, :desired_state, :running) != :stopped
  end

  defp unit_status_span("running"),
    do: Span.new("running", style: %Style{fg: :green, modifiers: [:bold]})

  defp unit_status_span("stopped"),
    do: Span.new("stopped", style: %Style{fg: :dark_gray, modifiers: [:bold]})

  defp unit_status_span("restarting"),
    do: Span.new("restarting", style: %Style{fg: :cyan, modifiers: [:bold]})

  defp unit_status_span("starting"),
    do: Span.new("starting", style: %Style{fg: :yellow, modifiers: [:bold]})

  defp unit_status_span("stopping"),
    do: Span.new("stopping", style: %Style{fg: :yellow, modifiers: [:bold]})

  defp unit_status_span("failed"),
    do: Span.new("failed", style: %Style{fg: :red, modifiers: [:bold]})

  defp unit_status_span(status),
    do: Span.new(status, style: %Style{fg: :yellow})

  defp live_status_span("up") do
    Span.new("up", style: %Style{fg: :green, modifiers: [:bold]})
  end

  defp live_status_span("restarting") do
    Span.new("restarting", style: %Style{fg: :cyan, modifiers: [:bold]})
  end

  defp live_status_span("shutting down") do
    Span.new("shutting down", style: %Style{fg: :yellow, modifiers: [:bold]})
  end

  defp live_status_span("degraded") do
    Span.new("degraded", style: %Style{fg: :yellow, modifiers: [:bold]})
  end

  defp live_status_span("down") do
    Span.new("down", style: %Style{fg: :red, modifiers: [:bold]})
  end

  defp live_status_span(status) do
    Span.new(status, style: %Style{fg: :red, modifiers: [:bold]})
  end

  defp machine_status_label(state, overview, node, node_status) do
    case Map.get(state, :pending_machine_actions, %{}) |> Map.get(node) do
      %{action: :restart} -> "restarting"
      %{action: :shutdown} -> "shutting down"
      _pending -> do_machine_status_label(node_status, overview, node)
    end
  end

  defp do_machine_status_label(nil, overview, node) do
    if node_live?(overview, node), do: "degraded", else: "down"
  end

  defp do_machine_status_label(node_status, overview, node) do
    cond do
      not node_live?(overview, node) -> "down"
      machine_issue_count(node, node_status) > 0 -> "degraded"
      true -> "up"
    end
  end

  defp node_live?(nil, _node), do: false

  defp node_live?(%{members: members}, node) do
    node in Map.get(members, :live_nodes, [])
  end

  defp normalize_selected_service(selected_service, services) do
    cond do
      selected_service in services -> selected_service
      services == [] -> nil
      true -> hd(services)
    end
  end

  defp selected_service_index(nil, _services), do: 0

  defp selected_service_index(selected_service, services) do
    Enum.find_index(services, fn
      %{name: name} -> name == selected_service
      service -> service == selected_service
    end) || 0
  end

  defp panel_block(title, color \\ :dark_gray) do
    %Block{
      title: " #{title} ",
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: color}
    }
  end

  defp interactive_panel_block(state, container, title, color \\ :dark_gray) do
    border_color =
      if Map.get(state, :focused_container) == container do
        :yellow
      else
        color
      end

    panel_block(title, border_color)
  end

  defp content_container(:machines), do: :machines_logs
  defp content_container(:services), do: :services_logs
  defp content_container(:logs), do: :logs_content

  defp next_view(view) do
    index = Enum.find_index(@views, &(&1 == view)) || 0
    Enum.at(@views, rem(index + 1, length(@views)))
  end

  defp focusable_containers(view) do
    Map.get(@focusable_containers, view, [:dashboard_services])
  end

  defp default_focused_container(view) do
    view
    |> focusable_containers()
    |> List.first()
  end

  defp normalize_focused_container(%{active_view: active_view} = state) do
    focusable = focusable_containers(active_view)
    focused = Map.get(state, :focused_container)

    if focused in focusable do
      state
    else
      %{state | focused_container: default_focused_container(active_view)}
    end
  end

  defp switch_view(state, view) do
    %{state | active_view: view, focused_container: default_focused_container(view)}
  end

  defp cycle_focused_container(%{active_view: active_view} = state) do
    containers = focusable_containers(active_view)
    current = Map.get(state, :focused_container, default_focused_container(active_view))
    index = Enum.find_index(containers, &(&1 == current)) || 0
    %{state | focused_container: Enum.at(containers, rem(index + 1, length(containers)))}
  end

  defp move_focused_container(state, direction) do
    case Map.get(state, :focused_container, default_focused_container(state.active_view)) do
      container when container in [:dashboard_services, :services_table, :map_canvas] ->
        move_table_or_map(state, :service, direction)

      :machines_table ->
        move_table_or_map(state, :machine, direction)

      container when container in [:machines_summary, :services_summary] ->
        move_summary_or_logs(state, :summary, direction)

      container when container in [:machines_logs, :services_logs, :logs_content] ->
        move_summary_or_logs(state, :content, direction)

      :logs_filter ->
        move_log_filter(state, direction)

      _ ->
        state
    end
  end

  defp move_table_or_map(state, :service, direction) when direction in [:up, :down] do
    move_primary_selection(state, if(direction == :up, do: -1, else: 1))
  end

  defp move_table_or_map(state, :machine, direction) when direction in [:up, :down] do
    move_node_selection(state, if(direction == :up, do: -1, else: 1))
  end

  defp move_table_or_map(state, _kind, _direction), do: state

  defp move_summary_or_logs(state, :summary, :up), do: scroll_summary(state, -1)
  defp move_summary_or_logs(state, :summary, :down), do: scroll_summary(state, 1)
  defp move_summary_or_logs(state, :summary, :left), do: scroll_summary(state, 0, -2)
  defp move_summary_or_logs(state, :summary, :right), do: scroll_summary(state, 0, 2)
  defp move_summary_or_logs(state, :content, :up), do: scroll_content(state, -1)
  defp move_summary_or_logs(state, :content, :down), do: scroll_content(state, 1)
  defp move_summary_or_logs(state, :content, :left), do: scroll_content(state, 0, -2)
  defp move_summary_or_logs(state, :content, :right), do: scroll_content(state, 0, 2)

  defp move_log_filter(state, direction) when direction in [:down, :right] do
    cycle_log_filter(state)
  end

  defp move_log_filter(state, direction) when direction in [:up, :left] do
    current = current_log_filter(state)
    index = Enum.find_index(@log_filters, &(&1 == current)) || 0
    prev = Enum.at(@log_filters, rem(index + length(@log_filters) - 1, length(@log_filters)))
    set_log_filter(state, prev)
  end

  defp handle_mouse_click(state, x, y) do
    case interactive_hit_target(state, x, y) do
      {:view, view} ->
        switch_view(state, view)

      {:log_filter, filter} ->
        state
        |> Map.put(:focused_container, :logs_filter)
        |> set_log_filter(filter)

      {:machine_row, index} ->
        state
        |> Map.put(:focused_container, :machines_table)
        |> select_machine_at(index)

      {:service_row, index} ->
        state
        |> Map.put(:focused_container, focus_service_container(state))
        |> select_service_at(index)

      {:container, container} ->
        %{state | focused_container: container}

      nil ->
        state
    end
  end

  defp handle_mouse_scroll(state, kind, x, y) do
    direction =
      case kind do
        "scroll_up" -> :up
        "scroll_down" -> :down
        "scroll_left" -> :left
        "scroll_right" -> :right
      end

    case interactive_hit_target(state, x, y) do
      {:view, _view} ->
        state

      {:log_filter, filter} ->
        state
        |> Map.put(:focused_container, :logs_filter)
        |> set_log_filter(filter)
        |> move_focused_container(direction)

      {:machine_row, _index} ->
        state
        |> Map.put(:focused_container, :machines_table)
        |> move_focused_container(direction)

      {:service_row, _index} ->
        state
        |> Map.put(:focused_container, focus_service_container(state))
        |> move_focused_container(direction)

      {:container, container} ->
        state
        |> Map.put(:focused_container, container)
        |> move_focused_container(direction)

      nil ->
        state |> move_focused_container(direction)
    end
  end

  defp focus_service_container(%{active_view: :dashboard}), do: :dashboard_services
  defp focus_service_container(_state), do: :services_table

  defp select_service_at(state, index) when is_integer(index) and index >= 0 do
    services = sorted_service_entries(state)

    case Enum.at(services, index) do
      nil -> state
      %{name: service} -> set_selected_service(state, service)
    end
  end

  defp select_service_at(state, _index), do: state

  defp select_machine_at(state, index) when is_integer(index) and index >= 0 do
    nodes = sorted_machine_entries(state)

    case Enum.at(nodes, index) do
      nil -> state
      %{node: node} -> set_selected_node(state, node)
    end
  end

  defp select_machine_at(state, _index), do: state

  defp set_selected_service(state, selected_service) do
    new_state =
      state
      |> Map.put(:selected_service, selected_service)
      |> reset_content_scroll()

    if selected_service == state.selected_service do
      new_state
    else
      request_refresh(new_state, :selection)
    end
  end

  defp set_selected_node(state, selected_node) do
    new_state =
      state
      |> Map.put(:selected_node, selected_node)
      |> reset_content_scroll()

    if selected_node == state.selected_node do
      new_state
    else
      request_refresh(new_state, :node_selection)
    end
  end

  defp busy_label(nil), do: "idle"
  defp busy_label(:reconcile), do: "reconciling cluster"
  defp busy_label({:refresh, :auto}), do: "auto-refreshing"
  defp busy_label({:refresh, :initial}), do: "loading dashboard"
  defp busy_label({:refresh, :manual}), do: "refreshing"
  defp busy_label({:refresh, :selection}), do: "loading selected service"
  defp busy_label({:refresh, :node_selection}), do: "loading selected machine"
  defp busy_label({:start, service}), do: "starting #{service}"
  defp busy_label({:stop, service}), do: "stopping #{service}"
  defp busy_label({:restart, service}) when is_binary(service), do: "restarting #{service}"

  defp busy_label({:node_service_action, action, _node, service}),
    do: "#{service_action_verb(action)} #{service} on selected machine"

  defp busy_label({:restart, node}) when is_atom(node), do: "restarting #{node_hostname(node)}"

  defp busy_label({:shutdown, node}) when is_atom(node),
    do: "shutting down #{node_hostname(node)}"

  defp busy_label(:apply), do: "applying config"
  defp busy_label(:dry_run), do: "running dry-run"
  defp busy_label({:update, :selected_machine}), do: "updating selected machine"
  defp busy_label({:update, _scope}), do: "updating cluster"
  defp busy_label(:update), do: "updating cluster"
  defp busy_label(_busy), do: "working"

  defp service_action_message(action, service, results) do
    owners =
      results
      |> Enum.map(fn {node, _entries} -> Atom.to_string(node) end)
      |> case do
        [] -> "no live nodes"
        values -> Enum.join(values, ", ")
      end

    "#{service_action_label(action)} requested for #{service} on #{owners}"
  end

  defp machine_action_message(action, node, _result, overview) do
    "#{machine_action_label(action)} requested for #{node_hostname(overview, node)}"
  end

  defp node_service_action_message(action, service, node, _result, overview) do
    "#{service_action_label(action)} requested for #{service} on #{node_hostname(overview, node)} only"
  end

  defp reconcile_message(results) do
    "reconcile completed on #{length(results)} live node(s)"
  end

  defp update_message(%{
         after_versions: after_versions,
         target_nodes: target_nodes,
         version_changed?: true
       }) do
    "update applied: target nodes now report #{version_summary(Map.take(after_versions, target_nodes))}"
  end

  defp update_message(%{after_versions: after_versions, target_nodes: target_nodes})
       when map_size(after_versions) > 0 do
    "update complete: target nodes report #{version_summary(Map.take(after_versions, target_nodes))}"
  end

  defp update_message(_result) do
    "cluster updated successfully"
  end

  defp refresh_message(%{diagnostic: diagnostic}, trigger) do
    if Remote.connected?(diagnostic) do
      prefix =
        case trigger do
          :auto -> "auto refresh complete"
          :selection -> "selected service refreshed"
          :node_selection -> "selected machine refreshed"
          _ -> "refresh complete"
        end

      "#{prefix}: connected to #{diagnostic.target}"
    else
      "refresh failed: #{Remote.doctor_result(diagnostic)}"
    end
  end

  defp put_flash(state, message) do
    %{state | flash: message, last_error: nil}
  end

  defp put_error(state, message) do
    %{state | last_error: message, flash: "last action failed"}
  end

  defp inline_status_text(message) do
    message
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> "ready"
      text -> text
    end
  end

  defp put_pending_machine_action(state, node, action) do
    pending_action = %{action: action, started_at_ms: System.monotonic_time(:millisecond)}

    Map.put(
      state,
      :pending_machine_actions,
      Map.put(Map.get(state, :pending_machine_actions, %{}), node, pending_action)
    )
  end

  defp note_input(state) do
    %{state | last_input_at_ms: System.monotonic_time(:millisecond)}
  end

  defp open_help_overlay(state) do
    %{state | help_overlay: true}
    |> put_flash("help overlay open")
  end

  defp close_help_overlay(state) do
    %{state | help_overlay: false}
    |> put_flash("help overlay closed")
  end

  defp event_transition(state) do
    state = note_input(state)

    if Map.get(state, :pending_action) do
      {:stop, state}
    else
      {:noreply, maybe_flush_pending_refresh(state)}
    end
  end

  defp reset_content_scroll(state) do
    %{
      state
      | summary_scroll_x: 0,
        summary_scroll_y: 0,
        content_scroll_x: 0,
        content_scroll_y: 0,
        log_scroll: 0
    }
  end

  defp summary_scroll(state) do
    {Map.get(state, :summary_scroll_y, 0), Map.get(state, :summary_scroll_x, 0)}
  end

  defp content_scroll(state) do
    {Map.get(state, :content_scroll_y, 0), Map.get(state, :content_scroll_x, 0)}
  end

  defp resolved_content_scroll(state, text, area) do
    if Map.get(state, :log_tail?, true) do
      {tail_scroll_y(text, area), Map.get(state, :content_scroll_x, 0)}
    else
      content_scroll(state)
    end
  end

  defp tail_scroll_y(text, area) do
    visible_height = max(area.height - 2, 1)
    max(text_line_count(text) - visible_height, 0)
  end

  defp scroll_summary(state, delta_y, delta_x \\ 0) do
    next_y = max(0, Map.get(state, :summary_scroll_y, 0) + delta_y)
    next_x = max(0, Map.get(state, :summary_scroll_x, 0) + delta_x)
    %{state | summary_scroll_y: next_y, summary_scroll_x: next_x}
  end

  defp scroll_content(state, delta_y, delta_x \\ 0) do
    next_y = max(0, Map.get(state, :content_scroll_y, 0) + delta_y)
    next_x = max(0, Map.get(state, :content_scroll_x, 0) + delta_x)

    state
    |> Map.put(:content_scroll_y, next_y)
    |> Map.put(:content_scroll_x, next_x)
    |> Map.put(:log_scroll, next_y)
    |> Map.put(:log_tail?, false)
  end

  defp reset_log_scroll(state) do
    %{state | content_scroll_x: 0, content_scroll_y: 0, log_scroll: 0}
  end

  defp toggle_log_tail(state) do
    enabled? = not Map.get(state, :log_tail?, true)
    message = if enabled?, do: "log tail enabled", else: "log tail paused"

    %{state | log_tail?: enabled?}
    |> put_flash(message)
  end

  defp open_log_search_prompt(state) do
    %{
      state
      | prompt: %{
          kind: :log_search,
          title: "search logs",
          label: "query",
          value: Map.get(state, :log_search_query) || ""
        }
    }
    |> put_flash("enter a log search query")
  end

  defp apply_log_search(state, query) do
    normalized = String.trim(query)

    state =
      %{
        state
        | log_search_query: blank_to_nil(normalized),
          log_search_match_index: 0,
          log_tail?: false
      }

    if normalized == "" do
      state
      |> reset_log_scroll()
      |> put_flash("log search cleared")
    else
      case log_search_match_lines(state) do
        [] ->
          state
          |> put_error("no log matches for #{inspect(normalized)}")

        [line | _rest] ->
          state
          |> scroll_to_log_line(line)
          |> put_flash("log search ready")
      end
    end
  end

  defp jump_log_search(state, direction) do
    case {Map.get(state, :log_search_query), log_search_match_lines(state)} do
      {nil, _matches} ->
        put_error(state, "start a log search with / first")

      {_query, []} ->
        put_error(state, "no log matches are available")

      {_query, matches} ->
        current = rem(Map.get(state, :log_search_match_index, 0), length(matches))
        next = rem(current + direction + length(matches), length(matches))

        state
        |> Map.put(:log_search_match_index, next)
        |> scroll_to_log_line(Enum.at(matches, next))
        |> put_flash("log search moved to match #{next + 1}/#{length(matches)}")
    end
  end

  defp log_search_match_lines(state) do
    query = Map.get(state, :log_search_query)

    if is_nil(query) do
      []
    else
      lowered_query = String.downcase(query)

      state
      |> current_log_text()
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.filter(fn {line, _index} ->
        String.contains?(String.downcase(line), lowered_query)
      end)
      |> Enum.map(&elem(&1, 1))
    end
  end

  defp scroll_to_log_line(state, line_number) do
    %{
      state
      | content_scroll_y: max(line_number, 0),
        log_scroll: max(line_number, 0),
        log_tail?: false
    }
  end

  defp cycle_table_sort(%{active_view: :machines} = state) do
    %{
      state
      | machine_sort:
          cycle_sort(Map.get(state, :machine_sort, {:host, :asc}), [:host, :status, :version])
    }
  end

  defp cycle_table_sort(state) do
    %{
      state
      | service_sort:
          cycle_sort(Map.get(state, :service_sort, {:name, :asc}), [:name, :replicas, :owners])
    }
  end

  defp reverse_table_sort(%{active_view: :machines} = state) do
    %{state | machine_sort: reverse_sort(Map.get(state, :machine_sort, {:host, :asc}))}
  end

  defp reverse_table_sort(state) do
    %{state | service_sort: reverse_sort(Map.get(state, :service_sort, {:name, :asc}))}
  end

  defp cycle_sort({field, direction}, fields) do
    index = Enum.find_index(fields, &(&1 == field)) || 0
    {Enum.at(fields, rem(index + 1, length(fields))), direction}
  end

  defp reverse_sort({field, :asc}), do: {field, :desc}
  defp reverse_sort({field, :desc}), do: {field, :asc}

  defp current_log_filter(state), do: Map.get(state, :log_filter, :all)

  defp cycle_log_filter(state) do
    current = current_log_filter(state)
    index = Enum.find_index(@log_filters, &(&1 == current)) || 0
    next = Enum.at(@log_filters, rem(index + 1, length(@log_filters)))
    set_log_filter(state, next)
  end

  defp set_log_filter(state, filter) when filter in @log_filters do
    if current_log_filter(state) == filter do
      state
    else
      %{state | log_filter: filter}
      |> reset_log_scroll()
      |> put_flash("log filter set to #{String.downcase(log_filter_label(filter))}")
    end
  end

  defp log_filter_for_key("1"), do: :all
  defp log_filter_for_key("2"), do: :errors
  defp log_filter_for_key("3"), do: :selected_machine
  defp log_filter_for_key("4"), do: :selected_service

  defp log_filter_label(:all), do: "ALL"
  defp log_filter_label(:errors), do: "ERRORS"
  defp log_filter_label(:selected_machine), do: "MACHINE"
  defp log_filter_label(:selected_service), do: "SERVICE"

  defp apply_message(%{dry_run: true}), do: "dry-run complete"
  defp apply_message(_result), do: "apply complete"

  defp recent_input?(%{last_input_at_ms: nil}), do: false

  defp recent_input?(state) do
    System.monotonic_time(:millisecond) - state.last_input_at_ms < @input_refresh_debounce_ms
  end

  defp schedule_deferred_refresh do
    Process.send_after(self(), :deferred_refresh, @input_refresh_debounce_ms)
  end

  defp queue_refresh(state, trigger) do
    %{state | pending_refresh: merge_refresh_trigger(state.pending_refresh, trigger)}
  end

  defp maybe_flush_pending_refresh(%{pending_refresh: nil} = state), do: state

  defp maybe_flush_pending_refresh(state) do
    cond do
      modal_open?(state) ->
        state

      recent_input?(state) ->
        schedule_deferred_refresh()
        state

      true ->
        flush_pending_refresh(state)
    end
  end

  defp flush_pending_refresh(%{pending_refresh: trigger} = state) do
    request_refresh(%{state | pending_refresh: nil}, trigger)
  end

  defp merge_refresh_trigger(nil, trigger), do: trigger
  defp merge_refresh_trigger(:auto, trigger), do: trigger
  defp merge_refresh_trigger(trigger, :auto), do: trigger
  defp merge_refresh_trigger(_existing, trigger), do: trigger

  defp stale_auto_refresh_result?(%{
         busy: {:refresh, :auto},
         job_started_at_ms: started_at_ms,
         last_input_at_ms: last_input_at_ms
       })
       when is_integer(started_at_ms) and is_integer(last_input_at_ms) do
    last_input_at_ms > started_at_ms
  end

  defp stale_auto_refresh_result?(_state), do: false

  defp prune_pending_machine_actions(pending_actions, overview) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(pending_actions, %{}, fn {node, %{started_at_ms: started_at_ms} = pending}, acc ->
      age_ms = now - started_at_ms
      node_live = node_live?(overview, node)

      keep? =
        cond do
          age_ms > 15_000 -> false
          node_live and age_ms > 3_000 -> false
          true -> true
        end

      if keep?, do: Map.put(acc, node, pending), else: acc
    end)
  end

  defp modal_open?(state) do
    not is_nil(Map.get(state, :prompt)) or
      not is_nil(Map.get(state, :rollout_confirmation)) or
      not is_nil(Map.get(state, :action_confirmation)) or
      Map.get(state, :help_overlay, false)
  end

  defp refresh_job?({:refresh, _trigger}), do: true
  defp refresh_job?(_busy), do: false

  defp apply_cluster_metrics(%{overview: nil}, history, cluster_metrics, metrics_sample) do
    {history, cluster_metrics, metrics_sample}
  end

  defp apply_cluster_metrics(
         %{overview: %{status: %{nodes: nodes}}, captured_at_ms: captured_at_ms},
         history,
         _cluster_metrics,
         previous_sample
       ) do
    sample = aggregate_cluster_metric_sample(nodes, captured_at_ms)
    cluster_metrics = present_cluster_metrics(sample, previous_sample)

    new_history = %{
      cpu: Enum.take(history.cpu ++ [cluster_metrics.cpu.pct], -40),
      memory: Enum.take(history.memory ++ [cluster_metrics.memory.pct], -40),
      disk: Enum.take(history.disk ++ [cluster_metrics.disk.pct], -40),
      network: Enum.take(history.network ++ [cluster_metrics.network.pct], -40)
    }

    {new_history, cluster_metrics, sample}
  end

  defp aggregate_cluster_metric_sample(nodes, captured_at_ms) do
    initial = %{
      captured_at_ms: captured_at_ms,
      cpu: %{used: 0.0, total: 0, legacy_pct_sum: 0, legacy_nodes: 0},
      memory: %{used: 0, total: 0, legacy_pct_sum: 0, legacy_nodes: 0},
      disk: %{used: 0, total: 0, legacy_pct_sum: 0, legacy_nodes: 0},
      network: %{counter: 0, total: 0, legacy_value_sum: 0, legacy_nodes: 0}
    }

    Enum.reduce(nodes, initial, fn {_node, node_status}, acc ->
      metrics = normalize_node_metrics(Map.get(node_status, :metrics, %{}))
      cpu = metrics.cpu
      memory = metrics.memory
      disk = metrics.disk
      network = metrics.network

      %{
        captured_at_ms: captured_at_ms,
        cpu: %{
          used: acc.cpu.used + Map.get(cpu, :used, 0.0),
          total: acc.cpu.total + Map.get(cpu, :total, 0),
          legacy_pct_sum: acc.cpu.legacy_pct_sum + Map.get(cpu, :legacy_pct, 0),
          legacy_nodes: acc.cpu.legacy_nodes + Map.get(cpu, :legacy_nodes, 0)
        },
        memory: %{
          used: acc.memory.used + Map.get(memory, :used, 0),
          total: acc.memory.total + Map.get(memory, :total, 0),
          legacy_pct_sum: acc.memory.legacy_pct_sum + Map.get(memory, :legacy_pct, 0),
          legacy_nodes: acc.memory.legacy_nodes + Map.get(memory, :legacy_nodes, 0)
        },
        disk: %{
          used: acc.disk.used + Map.get(disk, :used, 0),
          total: acc.disk.total + Map.get(disk, :total, 0),
          legacy_pct_sum: acc.disk.legacy_pct_sum + Map.get(disk, :legacy_pct, 0),
          legacy_nodes: acc.disk.legacy_nodes + Map.get(disk, :legacy_nodes, 0)
        },
        network: %{
          counter: acc.network.counter + network_counter(network),
          total: acc.network.total + Map.get(network, :total, 0),
          legacy_value_sum: acc.network.legacy_value_sum + Map.get(network, :legacy_value, 0),
          legacy_nodes: acc.network.legacy_nodes + Map.get(network, :legacy_nodes, 0)
        }
      }
    end)
  end

  defp present_cluster_metrics(sample, previous_sample) do
    cpu_pct =
      aggregate_percent(
        sample.cpu.used,
        sample.cpu.total,
        sample.cpu.legacy_pct_sum,
        sample.cpu.legacy_nodes
      )

    memory_pct =
      aggregate_percent(
        sample.memory.used,
        sample.memory.total,
        sample.memory.legacy_pct_sum,
        sample.memory.legacy_nodes
      )

    disk_pct =
      aggregate_percent(
        sample.disk.used,
        sample.disk.total,
        sample.disk.legacy_pct_sum,
        sample.disk.legacy_nodes
      )

    network_used =
      case previous_sample do
        %{captured_at_ms: previous_ms, network: %{counter: previous_counter}}
        when sample.captured_at_ms > previous_ms ->
          max(sample.network.counter - previous_counter, 0) * 1000 /
            (sample.captured_at_ms - previous_ms)

        _ ->
          0
      end

    network_pct =
      aggregate_percent(
        network_used,
        sample.network.total,
        sample.network.legacy_value_sum,
        sample.network.legacy_nodes
      )

    %{
      cpu: %{
        pct: cpu_pct,
        used: sample.cpu.used,
        total: sample.cpu.total,
        label: aggregate_label(sample.cpu.used, sample.cpu.total, sample.cpu.legacy_nodes, :cores)
      },
      memory: %{
        pct: memory_pct,
        used: sample.memory.used,
        total: sample.memory.total,
        label:
          aggregate_label(
            sample.memory.used,
            sample.memory.total,
            sample.memory.legacy_nodes,
            :bytes
          )
      },
      disk: %{
        pct: disk_pct,
        used: sample.disk.used,
        total: sample.disk.total,
        label:
          aggregate_label(sample.disk.used, sample.disk.total, sample.disk.legacy_nodes, :bytes)
      },
      network: %{
        pct: network_pct,
        used: network_used,
        total: sample.network.total,
        label: network_label(network_used, sample.network.total, sample.network.legacy_nodes)
      }
    }
  end

  defp default_cluster_metrics do
    %{
      cpu: %{pct: 0, used: 0.0, total: 0, label: "0 / 0 cores"},
      memory: %{pct: 0, used: 0, total: 0, label: "0 B / 0 B"},
      disk: %{pct: 0, used: 0, total: 0, label: "0 B / 0 B"},
      network: %{pct: 0, used: 0, total: 0, label: "0 B/s / unknown"}
    }
  end

  defp default_service_metrics do
    %{
      cpu: %{pct: 0, used: 0.0, total: 0, label: "0 / 0 cores"},
      memory: %{pct: 0, used: 0, total: 0, label: "0 B / 0 B"},
      disk: %{pct: 0, used: 0, total: 0, label: "0 B / 0 B"},
      network: %{pct: 0, used: 0, total: 0, label: "0 B/s / unknown"}
    }
  end

  defp apply_node_metrics(%{overview: nil}, previous_samples), do: {previous_samples, %{}}

  defp apply_node_metrics(
         %{overview: %{status: %{nodes: nodes}}, captured_at_ms: captured_at_ms},
         previous_samples
       ) do
    Enum.reduce(nodes, {%{}, %{}}, fn {node, node_status}, {samples, presented} ->
      sample = node_metric_sample(node_status, captured_at_ms)

      {
        Map.put(samples, node, sample),
        Map.put(presented, node, present_cluster_metrics(sample, Map.get(previous_samples, node)))
      }
    end)
  end

  defp node_metric_sample(node_status, captured_at_ms) do
    metrics = normalize_node_metrics(Map.get(node_status, :metrics, %{}))

    %{
      captured_at_ms: captured_at_ms,
      cpu: %{
        used: metrics.cpu.used,
        total: metrics.cpu.total,
        legacy_pct_sum: Map.get(metrics.cpu, :legacy_pct, 0),
        legacy_nodes: Map.get(metrics.cpu, :legacy_nodes, 0)
      },
      memory: %{
        used: metrics.memory.used,
        total: metrics.memory.total,
        legacy_pct_sum: Map.get(metrics.memory, :legacy_pct, 0),
        legacy_nodes: Map.get(metrics.memory, :legacy_nodes, 0)
      },
      disk: %{
        used: metrics.disk.used,
        total: metrics.disk.total,
        legacy_pct_sum: Map.get(metrics.disk, :legacy_pct, 0),
        legacy_nodes: Map.get(metrics.disk, :legacy_nodes, 0)
      },
      network: %{
        counter: network_counter(metrics.network),
        total: Map.get(metrics.network, :total, 0),
        legacy_value_sum: Map.get(metrics.network, :legacy_value, 0),
        legacy_nodes: Map.get(metrics.network, :legacy_nodes, 0)
      }
    }
  end

  defp apply_service_metrics(%{overview: nil}, previous_samples), do: {previous_samples, %{}}

  defp apply_service_metrics(
         %{overview: %{status: %{nodes: nodes}}, captured_at_ms: captured_at_ms},
         previous_samples
       ) do
    samples = aggregate_service_metric_samples(nodes, captured_at_ms)

    presented =
      Enum.into(samples, %{}, fn {service, sample} ->
        {service, present_service_metrics(sample, Map.get(previous_samples, service))}
      end)

    {samples, presented}
  end

  defp aggregate_service_metric_samples(nodes, captured_at_ms) do
    Enum.reduce(nodes, %{}, fn {node, node_status}, acc ->
      node_metrics = normalize_node_metrics(Map.get(node_status, :metrics, %{}))

      Enum.reduce(Map.get(node_status, :services, []), acc, fn service, service_acc ->
        owned_units = Enum.filter(service.units, &(&1.owner == node))

        if owned_units == [] do
          service_acc
        else
          sample =
            Enum.reduce(owned_units, initial_service_metric_sample(captured_at_ms), fn unit,
                                                                                       sample_acc ->
              unit_metrics = normalize_unit_metrics(Map.get(unit, :metrics, %{}))

              %{
                captured_at_ms: captured_at_ms,
                running_units:
                  sample_acc.running_units + if(unit.status == :running, do: 1, else: 0),
                started_at_ns:
                  earliest_started_at_ns(sample_acc.started_at_ns, unit_metrics.started_at_ns),
                cpu: %{
                  counter: sample_acc.cpu.counter + unit_metrics.cpu.usage_ns,
                  total: sample_acc.cpu.total
                },
                memory: %{
                  used: sample_acc.memory.used + unit_metrics.memory.used,
                  total: sample_acc.memory.total
                },
                disk: %{
                  used: sample_acc.disk.used + unit_metrics.disk.used,
                  total: sample_acc.disk.total
                },
                network: %{
                  counter: sample_acc.network.counter + unit_metrics.network.counter,
                  total: sample_acc.network.total
                }
              }
            end)
            |> add_service_totals(node_metrics)

          Map.update(service_acc, service.name, sample, fn existing ->
            merge_service_metric_samples(existing, sample, captured_at_ms)
          end)
        end
      end)
    end)
  end

  defp initial_service_metric_sample(captured_at_ms) do
    %{
      captured_at_ms: captured_at_ms,
      running_units: 0,
      started_at_ns: nil,
      cpu: %{counter: 0, total: 0},
      memory: %{used: 0, total: 0},
      disk: %{used: 0, total: 0},
      network: %{counter: 0, total: 0}
    }
  end

  defp add_service_totals(sample, node_metrics) do
    %{
      sample
      | cpu: %{sample.cpu | total: sample.cpu.total + node_metrics.cpu.total},
        memory: %{sample.memory | total: sample.memory.total + node_metrics.memory.total},
        disk: %{sample.disk | total: sample.disk.total + node_metrics.disk.total},
        network: %{
          sample.network
          | total: sample.network.total + Map.get(node_metrics.network, :total, 0)
        }
    }
  end

  defp merge_service_metric_samples(existing, sample, captured_at_ms) do
    %{
      captured_at_ms: captured_at_ms,
      running_units: existing.running_units + sample.running_units,
      started_at_ns: earliest_started_at_ns(existing.started_at_ns, sample.started_at_ns),
      cpu: %{
        counter: existing.cpu.counter + sample.cpu.counter,
        total: existing.cpu.total + sample.cpu.total
      },
      memory: %{
        used: existing.memory.used + sample.memory.used,
        total: existing.memory.total + sample.memory.total
      },
      disk: %{
        used: existing.disk.used + sample.disk.used,
        total: existing.disk.total + sample.disk.total
      },
      network: %{
        counter: existing.network.counter + sample.network.counter,
        total: existing.network.total + sample.network.total
      }
    }
  end

  defp present_service_metrics(sample, previous_sample) do
    elapsed_ms = service_elapsed_ms(sample, previous_sample)
    average_cpu = average_cpu_usage(sample)
    average_network = average_counter_rate(sample.network.counter, sample.started_at_ns)

    cpu_used =
      if elapsed_ms > 0 do
        rate_with_fallback(
          counter_delta(sample.cpu.counter, previous_sample, [:cpu, :counter]) /
            (elapsed_ms * 1_000_000),
          average_cpu,
          sample
        )
      else
        minimum_running_cpu(average_cpu, sample)
      end

    network_used =
      if elapsed_ms > 0 do
        rate_with_fallback(
          counter_delta(sample.network.counter, previous_sample, [:network, :counter]) * 1000 /
            elapsed_ms,
          average_network,
          sample
        )
      else
        average_network
      end

    %{
      cpu: %{
        pct: ratio_percent(cpu_used, sample.cpu.total),
        used: cpu_used,
        total: sample.cpu.total,
        label: aggregate_label(cpu_used, sample.cpu.total, 0, :cores)
      },
      memory: %{
        pct: ratio_percent(sample.memory.used, sample.memory.total),
        used: sample.memory.used,
        total: sample.memory.total,
        label: aggregate_label(sample.memory.used, sample.memory.total, 0, :bytes)
      },
      disk: %{
        pct: ratio_percent(sample.disk.used, sample.disk.total),
        used: sample.disk.used,
        total: sample.disk.total,
        label: aggregate_label(sample.disk.used, sample.disk.total, 0, :bytes)
      },
      network: %{
        pct: ratio_percent(network_used, sample.network.total),
        used: network_used,
        total: sample.network.total,
        label: network_label(network_used, sample.network.total, 0)
      }
    }
  end

  defp service_elapsed_ms(_sample, nil), do: 0

  defp service_elapsed_ms(sample, previous_sample) do
    max(sample.captured_at_ms - previous_sample.captured_at_ms, 0)
  end

  defp counter_delta(_current, nil, _path), do: 0

  defp counter_delta(current, previous_sample, path) do
    max(current - get_in(previous_sample, path), 0)
  end

  defp average_cpu_usage(%{cpu: %{counter: cpu_counter}, started_at_ns: started_at_ns}) do
    normalized_started_at_ns = normalize_started_at_ns(started_at_ns)
    age_ns = max(System.system_time(:nanosecond) - normalized_started_at_ns, 0)

    if normalized_started_at_ns != 0 and age_ns > 0 do
      cpu_counter / age_ns
    else
      0.0
    end
  end

  defp average_counter_rate(counter, started_at_ns) do
    normalized_started_at_ns = normalize_started_at_ns(started_at_ns)
    age_ns = max(System.system_time(:nanosecond) - normalized_started_at_ns, 0)

    if normalized_started_at_ns != 0 and age_ns > 0 do
      counter * 1_000_000_000 / age_ns
    else
      0
    end
  end

  defp rate_with_fallback(rate, _fallback, _sample) when rate > 0, do: rate
  defp rate_with_fallback(_rate, fallback, _sample) when fallback > 0, do: fallback
  defp rate_with_fallback(_rate, _fallback, sample), do: minimum_running_cpu(0.0, sample)

  defp minimum_running_cpu(value, %{running_units: running_units} = sample)
       when running_units > 0 and value <= 0 do
    if sample.memory.used > 0 or sample.disk.used > 0 or sample.network.counter > 0 do
      0.01
    else
      0.0
    end
  end

  defp minimum_running_cpu(value, _sample), do: value

  defp earliest_started_at_ns(nil, value), do: normalize_started_at_ns(value)
  defp earliest_started_at_ns(value, nil), do: normalize_started_at_ns(value)

  defp earliest_started_at_ns(left, right) do
    [normalize_started_at_ns(left), normalize_started_at_ns(right)]
    |> Enum.reject(&(&1 <= 0))
    |> case do
      [] -> 0
      values -> Enum.min(values)
    end
  end

  defp selected_machine_metrics(%{
         selected_node: selected_node,
         node_metrics_by_node: metrics_by_node
       }) do
    Map.get(metrics_by_node, selected_node, default_cluster_metrics())
  end

  defp selected_service_metrics(%{
         selected_service: selected_service,
         service_metrics_by_service: metrics_by_service
       }) do
    Map.get(metrics_by_service, selected_service, default_service_metrics())
  end

  defp network_counter(%{received: received, transmitted: transmitted}),
    do: received + transmitted

  defp network_counter(_network), do: 0

  defp normalize_node_metrics(metrics) when is_map(metrics) do
    %{
      cpu: normalize_capacity_metric(Map.get(metrics, :cpu, 0)),
      memory: normalize_capacity_metric(Map.get(metrics, :memory, 0)),
      disk: normalize_capacity_metric(Map.get(metrics, :disk, 0)),
      network: normalize_network_metric(Map.get(metrics, :network, 0))
    }
  end

  defp normalize_node_metrics(_metrics) do
    %{
      cpu: normalize_capacity_metric(0),
      memory: normalize_capacity_metric(0),
      disk: normalize_capacity_metric(0),
      network: normalize_network_metric(0)
    }
  end

  defp normalize_capacity_metric(%{used: used, total: total}),
    do: %{used: used, total: total, legacy_pct: 0, legacy_nodes: 0}

  defp normalize_capacity_metric(%{"used" => used, "total" => total}),
    do: %{used: used, total: total, legacy_pct: 0, legacy_nodes: 0}

  defp normalize_capacity_metric(value) when is_integer(value) or is_float(value) do
    pct = Float.round(value * 1.0, 1)
    %{used: 0, total: 0, legacy_pct: pct, legacy_nodes: 1}
  end

  defp normalize_capacity_metric(_value),
    do: %{used: 0, total: 0, legacy_pct: 0, legacy_nodes: 0}

  defp normalize_network_metric(%{received: _received, transmitted: _transmitted} = value) do
    Map.merge(%{total: 0, legacy_value: 0, legacy_nodes: 0}, value)
  end

  defp normalize_network_metric(%{"received" => received, "transmitted" => transmitted} = value) do
    %{
      received: received,
      transmitted: transmitted,
      total: Map.get(value, "total", 0),
      legacy_value: 0,
      legacy_nodes: 0
    }
  end

  defp normalize_network_metric(value) when is_integer(value) or is_float(value) do
    %{
      received: 0,
      transmitted: 0,
      total: 0,
      legacy_value: Float.round(value * 1.0, 1),
      legacy_nodes: 1
    }
  end

  defp normalize_network_metric(_value),
    do: %{received: 0, transmitted: 0, total: 0, legacy_value: 0, legacy_nodes: 0}

  defp normalize_unit_metrics(metrics) when is_map(metrics) do
    %{
      cpu: normalize_unit_cpu_metric(Map.get(metrics, :cpu, Map.get(metrics, "cpu", 0))),
      memory:
        normalize_unit_memory_metric(Map.get(metrics, :memory, Map.get(metrics, "memory", 0))),
      disk: normalize_unit_disk_metric(Map.get(metrics, :disk, Map.get(metrics, "disk", 0))),
      network:
        normalize_unit_counter_metric(Map.get(metrics, :network, Map.get(metrics, "network", 0))),
      started_at_ns:
        normalize_started_at_ns(
          Map.get(metrics, :started_at_ns, Map.get(metrics, "started_at_ns", 0))
        )
    }
  end

  defp normalize_unit_metrics(_metrics) do
    %{
      cpu: %{usage_ns: 0},
      memory: %{used: 0},
      disk: %{used: 0},
      network: %{counter: 0},
      started_at_ns: 0
    }
  end

  defp normalize_unit_cpu_metric(%{usage_ns: value}), do: %{usage_ns: value}
  defp normalize_unit_cpu_metric(%{"usage_ns" => value}), do: %{usage_ns: value}
  defp normalize_unit_cpu_metric(value) when is_integer(value), do: %{usage_ns: value}
  defp normalize_unit_cpu_metric(_value), do: %{usage_ns: 0}

  defp normalize_unit_memory_metric(%{used: value}), do: %{used: value}
  defp normalize_unit_memory_metric(%{"used" => value}), do: %{used: value}
  defp normalize_unit_memory_metric(value) when is_integer(value), do: %{used: value}
  defp normalize_unit_memory_metric(_value), do: %{used: 0}

  defp normalize_unit_disk_metric(%{used: value}), do: %{used: value}
  defp normalize_unit_disk_metric(%{"used" => value}), do: %{used: value}
  defp normalize_unit_disk_metric(value) when is_integer(value), do: %{used: value}
  defp normalize_unit_disk_metric(_value), do: %{used: 0}

  defp normalize_unit_counter_metric(%{counter: value}), do: %{counter: value}
  defp normalize_unit_counter_metric(%{"counter" => value}), do: %{counter: value}
  defp normalize_unit_counter_metric(value) when is_integer(value), do: %{counter: value}
  defp normalize_unit_counter_metric(_value), do: %{counter: 0}

  defp normalize_started_at_ns(value) when is_integer(value) and value != 0, do: value
  defp normalize_started_at_ns(_value), do: 0

  defp ratio_percent(_used, total) when total <= 0, do: 0.0
  defp ratio_percent(used, total), do: Float.round(used / total * 100, 1)

  defp aggregate_percent(_used, total, legacy_sum, legacy_nodes)
       when total <= 0 and legacy_nodes > 0 do
    Float.round(legacy_sum / legacy_nodes, 1)
  end

  defp aggregate_percent(used, total, _legacy_sum, _legacy_nodes), do: ratio_percent(used, total)

  defp aggregate_label(used, total, 0, :cores) when total > 0 do
    "#{format_decimal(used)} / #{total} cores"
  end

  defp aggregate_label(used, total, 0, :bytes) when total > 0 do
    "#{format_bytes(used)} / #{format_bytes(total)}"
  end

  defp aggregate_label(used, total, legacy_nodes, :cores) when total > 0 do
    "#{format_decimal(used)} / #{total} cores + #{legacy_nodes} legacy node(s)"
  end

  defp aggregate_label(used, total, legacy_nodes, :bytes) when total > 0 do
    "#{format_bytes(used)} / #{format_bytes(total)} + #{legacy_nodes} legacy node(s)"
  end

  defp aggregate_label(_used, _total, legacy_nodes, _kind) when legacy_nodes > 0 do
    "#{legacy_nodes} legacy node(s)"
  end

  defp aggregate_label(_used, _total, _legacy_nodes, :cores), do: "0 / 0 cores"
  defp aggregate_label(_used, _total, _legacy_nodes, :bytes), do: "0 B / 0 B"

  defp network_label(used, total, 0) when total > 0 do
    "#{format_bytes(used)}/s / #{format_bytes(total)}/s"
  end

  defp network_label(used, total, legacy_nodes) when total > 0 do
    "#{format_bytes(used)}/s / #{format_bytes(total)}/s + #{legacy_nodes} legacy node(s)"
  end

  defp network_label(_used, _total, legacy_nodes) when legacy_nodes > 0 do
    "#{legacy_nodes} legacy node(s)"
  end

  defp network_label(_used, _total, _legacy_nodes), do: "0 B/s / unknown"

  defp metric_panel_title(name, label, state) do
    title =
      case label do
        nil -> name
        "" -> name
        value -> "#{name} #{value}"
      end

    if stale_data?(state), do: "#{title} [stale]", else: title
  end

  defp stale_label(state), do: if(stale_data?(state), do: "stale", else: "live")

  defp stale_data?(state) do
    cond do
      is_nil(state.overview) ->
        true

      state.diagnostic && not Remote.connected?(state.diagnostic) ->
        true

      is_nil(state.last_snapshot_ms) ->
        true

      true ->
        System.monotonic_time(:millisecond) - state.last_snapshot_ms > state.refresh_ms * 2
    end
  end

  defp pad_lines_to_height(lines, height) do
    available_height = max(height - 2, 1)
    line_count = max(length(lines), 1)
    pad_bottom = max(available_height - line_count, 0)
    blank = Line.new([Span.new("")])

    lines ++ :lists.duplicate(pad_bottom, blank)
  end

  defp maybe_rollout_overlay(widgets, %{rollout_confirmation: nil}, _area), do: widgets

  defp maybe_rollout_overlay(widgets, %{rollout_confirmation: confirmation}, area) do
    overlay_height = min(12, max(length(confirmation.target_hosts) + 7, 8))
    overlay_width = min(max(area.width - 8, 40), 78)

    widgets ++
      [
        {%Paragraph{
           text: rollout_confirmation_text(confirmation),
           wrap: true,
           block: panel_block("confirm rollout", :yellow)
         }, centered_rect(area, overlay_width, overlay_height)}
      ]
  end

  defp maybe_action_confirmation_overlay(widgets, %{action_confirmation: nil}, _area), do: widgets

  defp maybe_action_confirmation_overlay(widgets, state, _area)
       when not is_map_key(state, :action_confirmation),
       do: widgets

  defp maybe_action_confirmation_overlay(widgets, %{action_confirmation: confirmation}, area) do
    widgets ++
      [
        {%Paragraph{
           text: confirmation.message,
           wrap: true,
           block: panel_block(confirmation.title, :yellow)
         }, centered_rect(area, min(max(area.width - 8, 52), 88), 8)}
      ]
  end

  defp maybe_prompt_overlay(widgets, state, area) do
    case Map.get(state, :prompt) do
      nil ->
        widgets

      prompt ->
        widgets ++
          [
            {%Paragraph{
               text: prompt_text(prompt),
               wrap: true,
               block: panel_block(prompt.title, :yellow)
             }, centered_rect(area, min(max(area.width - 8, 40), 88), 8)}
          ]
    end
  end

  defp maybe_help_overlay(widgets, state, area) do
    if Map.get(state, :help_overlay, false) do
      text = help_overlay_text(state.active_view)
      overlay_height = min(max(text_line_count(text) + 2, 10), max(area.height - 2, 10))
      overlay_width = min(max(area.width - 8, 52), 92)

      widgets ++
        [
          {%Paragraph{
             text: text,
             wrap: true,
             block: panel_block("help", :yellow)
           }, centered_rect(area, overlay_width, overlay_height)}
        ]
    else
      widgets
    end
  end

  defp rollout_confirmation_text(confirmation) do
    hosts =
      case confirmation.target_hosts do
        [] -> ["- no explicit hosts resolved"]
        values -> Enum.map(values, &"- #{&1}")
      end

    versions =
      case confirmation.current_versions do
        [] -> ["- no live version data yet"]
        rows -> Enum.map(rows, fn {node, version} -> "- #{node}: #{version}" end)
      end

    [
      "Prepared: #{confirmation.prepared_at}",
      "Scope: #{rollout_scope_label(confirmation.scope)}",
      "Targets:",
      Enum.join(hosts, "\n"),
      "",
      "Current live versions:",
      Enum.join(versions, "\n"),
      "",
      rollout_scope_hint(confirmation),
      "Press u or enter to apply. Press esc to cancel."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp prompt_text(prompt) do
    case Map.get(prompt, :kind) do
      :log_search ->
        [
          "#{prompt.label}:",
          prompt.value,
          "",
          "Press enter to search logs. Use n/N for next and previous matches."
        ]
        |> Enum.join("\n")

      _ ->
        [
          "#{prompt.label}:",
          prompt.value,
          "",
          "Press enter to confirm or esc to cancel."
        ]
        |> Enum.join("\n")
    end
  end

  defp help_overlay_text(:dashboard) do
    """
    Dashboard

    tab                 switch views
    shift+tab           cycle interactive containers
    arrows / j / k      move the focused service selection
    mouse click         focus a pane or select a row
    mouse wheel         scroll the focused or hovered pane
    o / O               cycle or reverse service table sorting
    b / z / x           start, stop, or restart the selected service
    Y / U               copy or export the selected service row
    r / enter           refresh
    q / esc / ?         close help or quit
    """
    |> String.trim()
  end

  defp help_overlay_text(:map) do
    """
    Map

    tab                 switch views
    shift+tab           cycle interactive containers
    arrows / j / k      change selected service
    mouse click         focus the map or switch views
    mouse wheel         move the focused selection
    r / enter           refresh
    q / esc / ?         close help or quit
    """
    |> String.trim()
  end

  defp help_overlay_text(:machines) do
    """
    Machines

    tab                 switch views
    shift+tab           cycle table, detail, and log panes
    arrows / hjkl       move or scroll the focused pane
    mouse click         focus a pane or select a machine row
    mouse wheel         scroll the hovered pane
    o / O               cycle or reverse machine sorting
    R / Z               restart or shut down the selected machine
    / then n / N        search logs and move between matches
    t                   toggle live log tailing
    C / E               copy or export the current logs
    Y / U               copy or export the selected machine row
    ? / esc             close help
    """
    |> String.trim()
  end

  defp help_overlay_text(:services) do
    """
    Services

    tab                 switch views
    shift+tab           cycle table, summary, and log panes
    arrows / hjkl       move or scroll the focused pane
    mouse click         focus a pane or select a service row
    mouse wheel         scroll the hovered pane
    o / O               cycle or reverse service sorting
    b / z / x           start, stop, or restart the selected service
    / then n / N        search logs and move between matches
    t                   toggle live log tailing
    C / E               copy or export the current logs
    Y / U               copy or export the selected service row
    ? / esc             close help
    """
    |> String.trim()
  end

  defp help_overlay_text(:logs) do
    """
    Logs

    tab                 switch views
    shift+tab           cycle logs and filter panes
    arrows / hjkl       move or scroll the focused pane
    mouse click         focus logs or select a filter tab
    mouse wheel         scroll the hovered pane
    1-4 / f             change the log filter
    / then n / N        search logs and move between matches
    t                   toggle live log tailing
    C / E               copy or export the current log view
    ? / esc             close help
    """
    |> String.trim()
  end

  defp centered_rect(area, width, height) do
    width = min(width, area.width)
    height = min(height, area.height)

    %Rect{
      x: area.x + max(div(area.width - width, 2), 0),
      y: area.y + max(div(area.height - height, 2), 0),
      width: width,
      height: height
    }
  end

  defp format_decimal(value) when is_float(value) do
    decimals =
      cond do
        value == 0.0 -> 1
        abs(value) < 10 -> 2
        true -> 1
      end

    rendered =
      value
      |> minimum_visible_float()
      |> :erlang.float_to_binary(decimals: decimals)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")

    if rendered == "-0", do: "0", else: rendered
  end

  defp format_decimal(value), do: to_string(value)

  defp minimum_visible_float(value) when value > 0 and value < 0.01, do: 0.01
  defp minimum_visible_float(value) when value < 0 and value > -0.01, do: -0.01
  defp minimum_visible_float(value), do: value

  defp format_bytes(value) when value <= 0, do: "0 B"

  defp format_bytes(value) do
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    do_format_bytes(value * 1.0, units)
  end

  defp do_format_bytes(value, [unit]) do
    "#{format_decimal(value)} #{unit}"
  end

  defp do_format_bytes(value, [unit | _rest]) when value < 1024 do
    "#{format_decimal(value)} #{unit}"
  end

  defp do_format_bytes(value, [_unit | rest]) do
    do_format_bytes(value / 1024, rest)
  end

  defp format_duration(seconds) when not is_integer(seconds) or seconds <= 0, do: "0s"

  defp format_duration(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    secs = rem(seconds, 60)

    []
    |> maybe_duration(days, "d")
    |> maybe_duration(hours, "h")
    |> maybe_duration(minutes, "m")
    |> maybe_duration(secs, "s")
    |> Enum.take(2)
    |> Enum.join(" ")
  end

  defp maybe_duration(parts, 0, _suffix), do: parts
  defp maybe_duration(parts, value, suffix), do: parts ++ ["#{value}#{suffix}"]

  defp format_selected_node(nil), do: "-"
  defp format_selected_node(node), do: Atom.to_string(node)

  defp rollout_scope_label(:selected_machine), do: "selected machine"
  defp rollout_scope_label(_scope), do: "cluster"

  defp rollout_scope_hint(%{available_scopes: scopes}) when is_list(scopes) do
    if :selected_machine in scopes do
      "Press c for cluster targets or m for the selected machine."
    end
  end

  defp rollout_scope_hint(_confirmation), do: nil

  defp node_hostname(nil, node), do: node_hostname(node)

  defp node_hostname(overview, node) when is_atom(node) do
    preferred_node_hostname(
      node
      |> Atom.to_string()
      |> fallback_node_hostname(),
      overview_node_hostname(overview, node)
    )
  end

  defp node_hostname(overview, node_name) when is_binary(node_name) do
    preferred_node_hostname(
      fallback_node_hostname(node_name),
      overview_node_hostname(overview, node_name)
    )
  end

  defp node_hostname(node) when is_atom(node) do
    preferred_node_hostname(
      node
      |> Atom.to_string()
      |> fallback_node_hostname(),
      configured_node_hostname(node)
    )
  end

  defp node_hostname(node_name) when is_binary(node_name) do
    preferred_node_hostname(
      fallback_node_hostname(node_name),
      configured_node_hostname(node_name)
    )
  end

  defp configured_node_hostname(node) when is_atom(node) do
    NixSwarm.Config.current().nodes
    |> Map.get(node, %{})
    |> Map.get(:deploy_host)
    |> deploy_host_hostname()
  end

  defp configured_node_hostname(node_name) when is_binary(node_name) do
    NixSwarm.Config.current().nodes
    |> Enum.find_value(fn {configured_node, attrs} ->
      if Atom.to_string(configured_node) == node_name do
        attrs
        |> Map.get(:deploy_host)
        |> deploy_host_hostname()
      end
    end)
  end

  defp overview_node_hostname(%{members: members}, node) when is_atom(node) do
    members
    |> Map.get(:deploy_hosts, %{})
    |> deploy_host_for_node(node)
    |> deploy_host_hostname()
  end

  defp overview_node_hostname(%{members: members}, node_name) when is_binary(node_name) do
    members
    |> Map.get(:deploy_hosts, %{})
    |> deploy_host_for_node(node_name)
    |> deploy_host_hostname()
  end

  defp overview_node_hostname(_overview, _node), do: nil

  defp deploy_host_hostname(nil), do: nil

  defp deploy_host_hostname(deploy_host) when is_binary(deploy_host) do
    deploy_host
    |> String.split("@", parts: 2)
    |> List.last()
  end

  defp fallback_node_hostname(node_name) when is_binary(node_name) do
    node_name
    |> String.split("@", parts: 2)
    |> List.last()
  end

  defp preferred_node_hostname(fallback, nil), do: fallback

  defp preferred_node_hostname(fallback, configured) when is_binary(fallback) do
    if ip_like_host?(fallback), do: configured, else: fallback
  end

  defp preferred_node_hostname(_fallback, configured), do: configured

  defp ip_like_host?(host) when is_binary(host) do
    Regex.match?(~r/\A\d{1,3}(?:\.\d{1,3}){3}\z/, host) or String.contains?(host, ":")
  end

  defp format_list([]), do: "-"
  defp format_list(values), do: Enum.map_join(values, ", ", &to_string/1)

  defp format_port_list([]), do: "-"
  defp format_port_list(ports), do: Enum.map_join(ports, ", ", &to_string/1)

  defp version_summary(versions) do
    case versions |> Map.values() |> Enum.uniq() do
      [] -> "-"
      [version] -> version
      many -> "#{length(many)} versions"
    end
  end

  defp cluster_update_status(nil), do: "unknown"

  defp cluster_update_status(overview) do
    if cluster_update_available?(overview) do
      "yes (mixed live versions)"
    else
      "no"
    end
  end

  defp selected_node_update_status(nil, _node), do: "unknown"
  defp selected_node_update_status(_overview, nil), do: "unknown"

  defp selected_node_update_status(overview, node) do
    reference_version = cluster_reference_version(overview)
    node_version = node_version(overview, node)

    cond do
      is_nil(node_version) ->
        "unknown"

      node_update_available?(overview, node) and reference_version ->
        "yes (control node reports #{reference_version})"

      true ->
        "no"
    end
  end

  defp cluster_update_available?(overview) do
    overview
    |> live_versions()
    |> Map.values()
    |> Enum.uniq()
    |> length() > 1
  end

  defp node_update_available?(overview, node) do
    (cluster_update_available?(overview) and
       cluster_reference_version(overview)) &&
      node_version(overview, node) != cluster_reference_version(overview)
  end

  defp cluster_reference_version(nil), do: nil

  defp cluster_reference_version(%{members: members} = overview) do
    queried_node = Map.get(members, :queried_node)

    node_version(overview, queried_node) ||
      case live_versions(overview) |> Map.values() |> Enum.uniq() do
        [version] -> version
        _ -> nil
      end
  end

  defp live_versions(nil), do: %{}

  defp live_versions(overview) do
    overview
    |> Map.get(:members, %{})
    |> Map.get(:live_nodes, [])
    |> Enum.map(fn node -> {Atom.to_string(node), node_version(overview, node)} end)
    |> Enum.reject(fn {_node, version} -> is_nil(version) end)
    |> Enum.into(%{})
  end

  defp node_version(_overview, nil), do: nil

  defp node_version(overview, node) do
    overview
    |> node_status_for(node)
    |> case do
      nil -> nil
      node_status -> Map.get(node_status, :version)
    end
  end

  defp node_version_cell(overview, node, node_status) do
    version = if(node_status, do: Map.get(node_status, :version, "unknown"), else: "unknown")

    if node_update_available?(overview, node) do
      Span.new("#{version} *", style: %Style{fg: :yellow, modifiers: [:bold]})
    else
      version
    end
  end

  defp machine_version_span(%{version: version, update_available?: true}) do
    Span.new("#{version} *", style: %Style{fg: :yellow, modifiers: [:bold]})
  end

  defp machine_version_span(%{version: version}), do: version

  defp rollout_version_rows(nil, _target_nodes), do: []

  defp rollout_version_rows(overview, []) do
    rollout_version_rows(overview, cluster_node_names(overview))
  end

  defp rollout_version_rows(overview, target_nodes) do
    cluster_nodes = cluster_node_names(overview)

    target_nodes
    |> Enum.map(fn node_name ->
      case resolve_rollout_node(node_name, cluster_nodes) do
        nil ->
          {to_string(node_name), "unknown"}

        node ->
          version =
            overview
            |> node_status_for(node)
            |> case do
              nil -> "unknown"
              node_status -> Map.get(node_status, :version, "unknown")
            end

          {Atom.to_string(node), version}
      end
    end)
  end

  defp resolve_rollout_node(node_name, cluster_nodes) when is_atom(node_name) do
    if node_name in cluster_nodes, do: node_name
  end

  defp resolve_rollout_node(node_name, cluster_nodes) do
    Enum.find(cluster_nodes, fn node -> Atom.to_string(node) == to_string(node_name) end)
  end

  defp maybe_notify_test(%{test_pid: nil}, _payload), do: :ok

  defp maybe_notify_test(%{test_pid: test_pid} = state, payload) do
    send(test_pid, {:tui_update, state, payload})
  end

  @impl true
  def terminate(_reason, %{owner_pid: owner_pid, pending_action: pending_action} = state)
      when not is_nil(owner_pid) and not is_nil(pending_action) do
    send(
      owner_pid,
      {:tui_external_action, pending_action,
       Map.take(state, [
         :active_view,
         :selected_service,
         :selected_node,
         :config_paths,
         :content_mode,
         :log_filter,
         :log_tail?,
         :log_search_query,
         :log_search_match_index,
         :service_sort,
         :machine_sort,
         :summary_scroll_x,
         :summary_scroll_y,
         :content_scroll_x,
         :content_scroll_y,
         :apply_result
       ])}
    )

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp schedule_tick(ms) do
    Process.send_after(self(), :tick, ms)
  end

  defp tick_needs_render?(%{active_view: :map}), do: true
  defp tick_needs_render?(%{loading: true}), do: true
  defp tick_needs_render?(%{busy: busy}) when not is_nil(busy), do: true
  defp tick_needs_render?(_), do: false

  defp schedule_refresh(ms) do
    Process.send_after(self(), :refresh, ms)
  end

  defp timestamp do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp run_session(start_opts, resume_state, editor_runner) do
    case start_link(Keyword.put(start_opts, :resume_state, resume_state)) do
      {:ok, pid} ->
        Process.unlink(pid)

        case wait_for_exit(pid, nil) do
          {:edit_file, path, next_resume_state} ->
            editor_runner.(path)
            run_session(start_opts, next_resume_state, editor_runner)

          {:copy_text, label, text, next_resume_state} ->
            next_resume_state =
              next_resume_state
              |> merge_external_action_result(copy_text_to_clipboard(text), label, :copy)

            run_session(start_opts, next_resume_state, editor_runner)

          {:export_text, label, text, next_resume_state} ->
            next_resume_state =
              next_resume_state
              |> merge_external_action_result(write_export_file(label, text), label, :export)

            run_session(start_opts, next_resume_state, editor_runner)

          nil ->
            :ok
        end

      {:error, reason} ->
        raise RuntimeError, message: "failed to start TUI: #{inspect(reason)}"
    end
  end

  defp run_system_editor(path) do
    editor = ConfigFiles.system_editor()
    [command | args] = OptionParser.split(editor)

    executable =
      System.find_executable(command) || raise ArgumentError, "editor not found: #{command}"

    port =
      Port.open({:spawn_executable, executable}, [
        :exit_status,
        :use_stdio,
        {:args, args ++ [path]}
      ])

    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> raise RuntimeError, "editor exited with status #{status}"
    end
  end

  defp merge_external_action_result(resume_state, {:ok, _detail}, label, :copy) do
    Map.merge(resume_state, %{flash: "copied #{label} to clipboard", last_error: nil})
  end

  defp merge_external_action_result(resume_state, {:ok, path}, _label, :export) do
    Map.merge(resume_state, %{flash: "exported view to #{path}", last_error: nil})
  end

  defp merge_external_action_result(resume_state, {:error, message}, _label, _action) do
    Map.merge(resume_state, %{flash: "last action failed", last_error: message})
  end

  defp copy_text_to_clipboard(text) do
    case clipboard_command() do
      nil ->
        {:error, "no clipboard tool found (tried wl-copy, xclip, xsel, pbcopy)"}

      {command, args} ->
        case System.cmd(command, args, input: text, stderr_to_stdout: true) do
          {_output, 0} -> {:ok, command}
          {output, _status} -> {:error, "clipboard copy failed: #{String.trim(output)}"}
        end
    end
  end

  defp clipboard_command do
    Enum.find_value(
      [
        {"wl-copy", []},
        {"xclip", ["-selection", "clipboard"]},
        {"xsel", ["--clipboard", "--input"]},
        {"pbcopy", []}
      ],
      fn {command, args} ->
        if System.find_executable(command), do: {command, args}
      end
    )
  end

  defp write_export_file(label, text) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{sanitize_export_label(label)}-#{System.unique_integer([:positive])}.txt"
      )

    case File.write(path, text) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "failed to export view: #{inspect(reason)}"}
    end
  end

  defp sanitize_export_label(label) do
    label
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "nix-swarm-export"
      sanitized -> sanitized
    end
  end

  defp wait_for_exit(pid, pending_action) do
    ref = Process.monitor(pid)

    receive do
      {:tui_external_action, action, resume_state} ->
        wait_for_exit(pid, {action, resume_state})

      {:DOWN, ^ref, :process, ^pid, reason} ->
        case reason do
          :normal -> unpack_exit_action(pending_action)
          :shutdown -> unpack_exit_action(pending_action)
          {:shutdown, _detail} -> unpack_exit_action(pending_action)
          other -> raise RuntimeError, message: "TUI exited unexpectedly: #{inspect(other)}"
        end
    end
  end

  defp unpack_exit_action({{:edit_file, path}, resume_state}),
    do: {:edit_file, path, resume_state}

  defp unpack_exit_action({{:copy_text, label, text}, resume_state}),
    do: {:copy_text, label, text, resume_state}

  defp unpack_exit_action({{:export_text, label, text}, resume_state}),
    do: {:export_text, label, text, resume_state}

  defp unpack_exit_action(_pending_action), do: nil
end
