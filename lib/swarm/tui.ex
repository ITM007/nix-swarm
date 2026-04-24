defmodule Swarm.TUI do
  @moduledoc false

  use ExRatatui.App

  alias ExRatatui.Event
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Gauge, List, Paragraph, Table, Tabs, Throbber}
  alias Swarm.{Ascii, ConfigFiles, Deploy, Remote, Update}

  @default_lines 50
  @default_refresh_ms 3_000
  @views [:dashboard, :map, :machines, :services, :logs]
  @input_refresh_debounce_ms 750

  @type state :: map()

  def run(opts) do
    ensure_runtime_supported!()
    remote = Remote.options!(opts)

    config_paths =
      ConfigFiles.defaults(Keyword.get(opts, :source, "."))
      |> Map.merge(%{
        cluster_file:
          Keyword.get(
            opts,
            :cluster_file,
            ConfigFiles.defaults(Keyword.get(opts, :source, ".")).cluster_file
          ),
        machines_dir:
          Keyword.get(
            opts,
            :machines_dir,
            ConfigFiles.defaults(Keyword.get(opts, :source, ".")).machines_dir
          ),
        services_dir:
          Keyword.get(
            opts,
            :services_dir,
            ConfigFiles.defaults(Keyword.get(opts, :source, ".")).services_dir
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
      mix run -e 'Swarm.CLI.main(System.argv())' -- --target NODE
      swarm --target NODE

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
        content_mode: :logs,
        content_scroll_x: 0,
        content_scroll_y: 0,
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
      |> Map.merge(Keyword.get(opts, :resume_state, %{}))

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

  def handle_event(%Event.Key{code: code, kind: "press"}, state) when code in ["q", "esc"] do
    {:stop, state}
  end

  def handle_event(%Event.Key{code: "tab", kind: kind}, state)
      when kind in [nil, "press", "repeat"] do
    {:noreply, state |> Map.put(:active_view, next_view(state.active_view)) |> note_input()}
  end

  def handle_event(%Event.Key{code: "left", modifiers: modifiers, kind: "press"}, state)
      when modifiers in [nil, []] do
    {:noreply, state |> Map.put(:active_view, previous_view(state.active_view)) |> note_input()}
  end

  def handle_event(%Event.Key{code: "right", modifiers: modifiers, kind: "press"}, state)
      when modifiers in [nil, []] do
    {:noreply, state |> Map.put(:active_view, next_view(state.active_view)) |> note_input()}
  end

  def handle_event(
        %Event.Key{code: code, modifiers: modifiers, kind: "press"},
        %{active_view: :logs} = state
      )
      when code in ["up", "k"] and modifiers in [nil, []] do
    {:noreply,
     state
     |> Map.put(:content_scroll_y, max(0, state.content_scroll_y - 1))
     |> Map.put(:log_scroll, max(0, state.content_scroll_y - 1))
     |> note_input()}
  end

  def handle_event(
        %Event.Key{code: code, modifiers: modifiers, kind: "press"},
        %{active_view: :logs} = state
      )
      when code in ["down", "j"] and modifiers in [nil, []] do
    {:noreply,
     state
     |> Map.put(:content_scroll_y, state.content_scroll_y + 1)
     |> Map.put(:log_scroll, state.content_scroll_y + 1)
     |> note_input()}
  end

  def handle_event(%Event.Key{code: code, modifiers: modifiers, kind: "press"}, state)
      when code in ["up", "k"] and modifiers in [nil, []] do
    {:noreply, state |> move_primary_selection(-1) |> note_input()}
  end

  def handle_event(%Event.Key{code: code, modifiers: modifiers, kind: "press"}, state)
      when code in ["down", "j"] and modifiers in [nil, []] do
    {:noreply, state |> move_primary_selection(1) |> note_input()}
  end

  def handle_event(%Event.Key{code: "r", kind: "press"}, state) do
    {:noreply, state |> request_refresh(:manual) |> note_input()}
  end

  def handle_event(%Event.Key{code: "enter", kind: "press"}, state) do
    {:noreply, state |> request_refresh(:manual) |> note_input()}
  end

  def handle_event(%Event.Key{code: "x", kind: "press"}, state) do
    {:noreply, state |> request_restart() |> note_input()}
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

  def handle_event(%Event.Key{code: code, modifiers: ["shift"], kind: "press"}, state)
      when code in ["up", "k"] do
    {:noreply,
     state
     |> Map.put(:content_scroll_y, max(0, state.content_scroll_y - 1))
     |> Map.put(:log_scroll, max(0, state.content_scroll_y - 1))
     |> note_input()}
  end

  def handle_event(%Event.Key{code: code, modifiers: ["shift"], kind: "press"}, state)
      when code in ["down", "j"] do
    {:noreply,
     state
     |> Map.put(:content_scroll_y, state.content_scroll_y + 1)
     |> Map.put(:log_scroll, state.content_scroll_y + 1)
     |> note_input()}
  end

  def handle_event(%Event.Key{code: code, modifiers: ["shift"], kind: "press"}, state)
      when code in ["left", "h"] do
    {:noreply,
     state |> Map.put(:content_scroll_x, max(0, state.content_scroll_x - 2)) |> note_input()}
  end

  def handle_event(%Event.Key{code: code, modifiers: ["shift"], kind: "press"}, state)
      when code in ["right", "l"] do
    {:noreply, state |> Map.put(:content_scroll_x, state.content_scroll_x + 2) |> note_input()}
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
          |> maybe_switch_to_apply_result(payload)
          |> apply_snapshot(payload.snapshot)

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
      updated_state = %{
        state
        | loading: false,
          busy: nil,
          job_ref: nil,
          job_started_at_ms: nil,
          flash: "last action failed",
          last_error: message
      }

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

  defp request_restart(%{selected_service: nil} = state) do
    put_flash(state, "select a service before restarting")
  end

  defp request_restart(%{job_ref: nil, selected_service: service} = state) do
    launch_job(state, {:restart, service}, fn ->
      node = Remote.connect!(state.remote)
      results = Remote.rpc!(node, Swarm.API, :restart_service, [service])
      snapshot = fetch_snapshot(state.remote, state.lines, service, state.selected_node)

      %{
        snapshot: snapshot,
        flash: restart_message(service, results)
      }
    end)
  end

  defp request_restart(state), do: state

  defp request_reconcile(%{job_ref: nil} = state) do
    launch_job(state, :reconcile, fn ->
      node = Remote.connect!(state.remote)
      results = Remote.rpc!(node, Swarm.API, :reconcile_cluster, [])

      snapshot =
        fetch_snapshot(state.remote, state.lines, state.selected_service, state.selected_node)

      %{
        snapshot: snapshot,
        flash: reconcile_message(results)
      }
    end)
  end

  defp request_reconcile(state), do: state

  defp request_update(%{job_ref: nil, rollout_confirmation: nil} = state) do
    %{state | rollout_confirmation: build_rollout_confirmation(state)}
    |> put_flash("rollout ready: press u or enter to confirm, esc to cancel")
  end

  defp request_update(%{job_ref: nil} = state) do
    confirm_rollout(state)
  end

  defp request_update(state), do: state

  defp confirm_rollout(%{rollout_confirmation: %{deploy_opts: deploy_opts}} = state) do
    launch_job(%{state | rollout_confirmation: nil}, :update, fn ->
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

  defp request_apply(state, _dry_run?), do: state

  defp cancel_prompt(state) do
    %{state | prompt: nil}
    |> put_flash("prompt cancelled")
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

  defp submit_prompt(state) do
    %{state | prompt: nil}
    |> put_error("confirmation did not match")
  end

  defp build_rollout_confirmation(state) do
    deploy_opts =
      rollout_base_opts(state)
      |> Update.effective_deploy_opts(%{overview: state.overview})

    target_hosts = Keyword.get(deploy_opts, :hosts, [])
    target_nodes = Update.target_nodes(%{overview: state.overview}, target_hosts)

    %{
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

  defp fetch_snapshot(remote, lines, selected_service, selected_node) do
    diagnostic = Remote.diagnose_connection(remote)

    if Remote.connected?(diagnostic) do
      overview = Remote.rpc!(diagnostic.target_node, Swarm.API, :cluster_overview, [])
      services = service_names(overview)
      selected_service = normalize_selected_service(selected_service, services)
      selected_node = normalize_selected_node(selected_node, overview)

      service_logs =
        if selected_service do
          Remote.rpc!(diagnostic.target_node, Swarm.API, :logs, [selected_service, lines])
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
    if remote_function_exported?(target_node, Swarm.API, :cluster_logs, 2) &&
         remote_function_exported?(selected_node, Swarm.API, :local_cluster_logs, 1) do
      Remote.rpc!(target_node, Swarm.API, :cluster_logs, [selected_node, lines])
    else
      legacy_cluster_logs(selected_node, overview)
    end
  end

  defp remote_function_exported?(node, module, function, arity) do
    case :rpc.call(node, :erlang, :function_exported, [module, function, arity], 5_000) do
      true -> true
      _ -> false
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
        service_metrics_by_service: service_metrics_by_service
    }
  end

  defp body_widgets(state, area) do
    widgets =
      case state.active_view do
        :dashboard -> dashboard_widgets(state, area)
        :map -> map_widgets(state, area)
        :machines -> machines_widgets(state, area)
        :services -> services_widgets(state, area)
        :logs -> logs_widgets(state, area)
      end

    widgets
    |> maybe_rollout_overlay(state, area)
    |> maybe_prompt_overlay(state, area)
  end

  defp map_widgets(state, area) do
    content = map_ascii(state)

    [
      {%Paragraph{
         text: pad_lines_to_height(content, area.height),
         wrap: false,
         alignment: :center,
         block: panel_block("cluster map")
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
        {service_list_widget(state), services_area},
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
        {:percentage, 28},
        {:percentage, 72}
      ])

    [summary_area, metrics_area, services_area, content_area] =
      Layout.split(right, :vertical, [
        {:length, 12},
        {:length, 10},
        {:length, 9},
        {:min, 10}
      ])

    [
      {node_list_widget(state, "machines"), left},
      {%Paragraph{
         text: machine_context_text(state),
         wrap: false,
         scroll: {state.content_scroll_y, state.content_scroll_x},
         block: panel_block("machine detail")
       }, summary_area}
      | metric_grid_widgets(selected_machine_metrics(state), metrics_area, state)
    ] ++
      [
        {doctor_checks_widget(state), services_area},
        {content_widget(state, :machines), content_area}
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

    [
      {service_list_widget(state), left},
      {%Paragraph{
         text: selected_service_summary(state),
         wrap: false,
         scroll: {state.content_scroll_y, state.content_scroll_x},
         block: panel_block("service summary")
       }, summary_area}
      | metric_grid_widgets(selected_service_metrics(state), metrics_area, state)
    ] ++
      [
        {service_detail_widget(state), detail_area},
        {content_widget(state, :services), content_area}
      ]
  end

  defp logs_widgets(state, area) do
    [
      {%Paragraph{
         text: cluster_event_log_text(state),
         wrap: false,
         scroll: {state.content_scroll_y, state.content_scroll_x},
         block: panel_block("cluster logs")
       }, area}
    ]
  end

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

  defp footer_widget(state) do
    flash_color = if state.last_error, do: :light_red, else: :green
    message = state.last_error || state.flash || "ready"

    keys =
      if state.rollout_confirmation do
        [
          Span.new("u/enter", style: %Style{fg: :cyan}),
          Span.new(" confirm rollout | "),
          Span.new("esc", style: %Style{fg: :cyan}),
          Span.new(" cancel | "),
          Span.new("shift+j/k", style: %Style{fg: :cyan}),
          Span.new(" scroll")
        ]
      else
        [
          Span.new("q/esc", style: %Style{fg: :cyan}),
          Span.new(" quit | "),
          Span.new("tab", style: %Style{fg: :cyan}),
          Span.new(" view | "),
          Span.new(primary_navigation_label(state), style: %Style{fg: :cyan}),
          Span.new(" | "),
          Span.new("enter/r", style: %Style{fg: :cyan}),
          Span.new(" refresh | "),
          Span.new("x", style: %Style{fg: :cyan}),
          Span.new(" restart | "),
          Span.new("c", style: %Style{fg: :cyan}),
          Span.new(" reconcile | "),
          Span.new("u", style: %Style{fg: :cyan}),
          Span.new(" update | "),
          Span.new("P/y", style: %Style{fg: :cyan}),
          Span.new(" apply/dry-run | "),
          Span.new("shift+h/j/k/l", style: %Style{fg: :cyan}),
          Span.new(" scroll")
        ]
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

  defp primary_navigation_label(%{active_view: :machines}), do: "j/k machine"
  defp primary_navigation_label(%{active_view: :services}), do: "j/k service"
  defp primary_navigation_label(%{active_view: :logs}), do: "j/k scroll"
  defp primary_navigation_label(_state), do: "j/k service"

  defp service_list_widget(state) do
    services = service_names(state.overview)
    selected_index = selected_service_index(state.selected_service, services)

    items =
      case services do
        [] ->
          ["(no services loaded yet)"]

        _ ->
          Enum.map(services, &service_item_label(state.overview, &1))
      end

    %List{
      items: items,
      selected: selected_index,
      highlight_symbol: "> ",
      highlight_style: %Style{fg: :yellow, modifiers: [:bold]},
      block: panel_block("services")
    }
  end

  defp node_list_widget(%{overview: nil}, title) do
    %Paragraph{
      text: "Waiting for the first successful refresh.",
      wrap: true,
      block: panel_block(title)
    }
  end

  defp node_list_widget(state, title) do
    nodes = cluster_node_names(state.overview)
    selected_index = selected_node_index(state.selected_node, nodes)

    items =
      case nodes do
        [] ->
          ["(no nodes loaded yet)"]

        _ ->
          Enum.map(nodes, &node_item_label(state.overview, &1))
      end

    %List{
      items: items,
      selected: selected_index,
      highlight_symbol: "> ",
      highlight_style: %Style{fg: :yellow, modifiers: [:bold]},
      block: panel_block(title)
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
            owned_total = owned_total + length(service.local_owned_slots)
            running_total = running_total + Enum.count(service.units, &(&1.status == :running))
            {owned_total, running_total}
          end)

        version = Map.get(node_status, :version, "unknown")
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
          o_service = length(service.local_owned_slots)
          r_service = Enum.count(service.units, &(&1.status == :running))
          {r + r_service, o + o_service}
        end)
      end)

    ratio = if total_owned > 0, do: min(total_running / total_owned, 1.0), else: 0.0
    label = "#{total_running}/#{total_owned} running (#{round(ratio * 100)}%)"

    color =
      cond do
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

          status_span =
            case status do
              "running" -> Span.new("running", style: %Style{fg: :green})
              "stopped" -> Span.new("stopped", style: %Style{fg: :dark_gray})
              _ -> Span.new(status, style: %Style{fg: :yellow})
            end

          [
            Integer.to_string(slot.slot),
            Atom.to_string(slot.owner),
            slot.unit,
            status_span
          ]
        end)
      end

    %Table{
      header: ["slot", "owner", "unit", "status"],
      rows: rows,
      widths: [{:length, 6}, {:percentage, 34}, {:percentage, 38}, {:length, 10}],
      block: panel_block("service detail#{if(service, do: " #{service}", else: "")}")
    }
  end

  defp doctor_checks_widget(%{overview: nil}) do
    %Table{
      header: ["service", "owned", "running", "units"],
      rows: [["-", "-", "-", "waiting for the first cluster refresh"]],
      widths: [{:percentage, 24}, {:length, 8}, {:length, 9}, {:percentage, 59}],
      block: panel_block("machine services")
    }
  end

  defp doctor_checks_widget(state) do
    rows =
      case selected_node_services(state) do
        [] ->
          [["-", "-", "-", "no services are currently placed on this node"]]

        services ->
          Enum.map(services, fn service ->
            running = Enum.count(service.units, &(&1.status == :running))

            [
              service.name,
              Integer.to_string(length(service.local_owned_slots)),
              Integer.to_string(running),
              Enum.map_join(service.units, ", ", & &1.unit)
            ]
          end)
      end

    %Table{
      header: ["service", "owned", "running", "units"],
      rows: rows,
      widths: [{:percentage, 24}, {:length, 8}, {:length, 9}, {:percentage, 59}],
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

    uptime =
      Map.get(node_status || %{}, :metrics, %{}) |> Map.get(:uptime, 0) |> format_duration()

    [
      "node: #{format_selected_node(node)}",
      "live: #{if(node_live?(state.overview, node), do: "yes", else: "no")}",
      "version: #{version}",
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
    cond do
      not node_live?(overview, node) ->
        "The selected node is not live, so cluster logs are unavailable."

      String.trim(cluster_logs) == "" ->
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
    case Map.get(state, :cluster_event_logs, "") |> String.trim() do
      "" -> "No cluster log data is available yet."
      output -> output
    end
  end

  defp content_widget(state, view) do
    {title, text} = content_panel(state, view)

    %Paragraph{
      text: text,
      wrap: false,
      scroll: {state.content_scroll_y, state.content_scroll_x},
      block: panel_block(title)
    }
  end

  defp content_panel(state, view) do
    case view do
      :machines -> {"machine logs", cluster_log_text(state)}
      :services -> {"service logs", log_text(state)}
      :logs -> {"cluster logs", cluster_event_log_text(state)}
    end
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

  defp rollout_summary_widget(%{last_rollout: nil}) do
    %Paragraph{
      text: "Last successful update: none yet",
      wrap: true,
      block: panel_block("rollout summary")
    }
  end

  defp rollout_summary_widget(%{last_rollout: rollout}) do
    target_hosts = Map.get(rollout, :target_hosts, [])
    version = version_summary(Map.get(rollout, :after_versions, %{}))

    %Paragraph{
      text:
        "Last successful update: #{Map.get(rollout, :completed_at, "-")}\nVersion: #{version}\nTargets: #{if(target_hosts == [], do: "-", else: Enum.join(target_hosts, ", "))}",
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
    services = service_names(state.overview)

    case services do
      [] ->
        state

      _ ->
        current_index = selected_service_index(state.selected_service, services)
        new_index = clamp(current_index + delta, 0, length(services) - 1)
        selected_service = Enum.at(services, new_index)

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
    nodes = cluster_node_names(state.overview)

    case nodes do
      [] ->
        state

      _ ->
        current_index = selected_node_index(state.selected_node, nodes)
        new_index = clamp(current_index + delta, 0, length(nodes) - 1)
        selected_node = Enum.at(nodes, new_index)

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

  defp service_names(nil), do: []

  defp service_names(%{status: %{placements: placements}}) do
    placements
    |> Map.keys()
    |> Enum.sort()
  end

  defp service_item_label(nil, service), do: service

  defp service_item_label(%{status: %{placements: placements}}, service) do
    slots = Map.get(placements, service, [])
    owners = slots |> Enum.map(& &1.owner) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    "#{service}  replicas=#{length(slots)} owners=#{length(owners)}"
  end

  defp cluster_node_names(nil), do: []

  defp cluster_node_names(%{members: members, status: status}) do
    (members.configured_nodes ++ members.live_nodes ++ Enum.map(status.nodes, &elem(&1, 0)))
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
    Enum.find_index(nodes, &(&1 == selected_node)) || 0
  end

  defp node_item_label(overview, node) do
    status =
      if node_live?(overview, node) do
        "up"
      else
        "down"
      end

    version =
      overview
      |> node_status_for(node)
      |> case do
        nil -> "unknown"
        node_status -> Map.get(node_status, :version, "unknown")
      end

    "#{Atom.to_string(node)}  #{status}  #{version}"
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
    Map.get(Map.get(members, :deploy_hosts, %{}), selected_node)
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
    Enum.find_index(services, &(&1 == selected_service)) || 0
  end

  defp panel_block(title, color \\ :dark_gray) do
    %Block{
      title: " #{title} ",
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: color}
    }
  end

  defp next_view(view) do
    index = Enum.find_index(@views, &(&1 == view)) || 0
    Enum.at(@views, rem(index + 1, length(@views)))
  end

  defp previous_view(view) do
    index = Enum.find_index(@views, &(&1 == view)) || 0
    Enum.at(@views, rem(index + length(@views) - 1, length(@views)))
  end

  defp busy_label(nil), do: "idle"
  defp busy_label(:reconcile), do: "reconciling cluster"
  defp busy_label({:refresh, :auto}), do: "auto-refreshing"
  defp busy_label({:refresh, :initial}), do: "loading dashboard"
  defp busy_label({:refresh, :manual}), do: "refreshing"
  defp busy_label({:refresh, :selection}), do: "loading selected service"
  defp busy_label({:refresh, :node_selection}), do: "loading selected machine"
  defp busy_label({:restart, service}), do: "restarting #{service}"
  defp busy_label(:apply), do: "applying config"
  defp busy_label(:dry_run), do: "running dry-run"
  defp busy_label(:update), do: "updating cluster"
  defp busy_label(_busy), do: "working"

  defp restart_message(service, results) do
    owners =
      results
      |> Enum.map(fn {node, _entries} -> Atom.to_string(node) end)
      |> Enum.join(", ")

    "restart requested for #{service} on #{owners}"
  end

  defp reconcile_message(results) do
    "reconcile completed on #{length(results)} live node(s)"
  end

  defp update_message(%{after_versions: after_versions, version_changed?: true}) do
    "cluster updated: live nodes now report #{version_summary(after_versions)}"
  end

  defp update_message(%{after_versions: after_versions}) when map_size(after_versions) > 0 do
    "cluster applied: live nodes still report #{version_summary(after_versions)}"
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

  defp note_input(state) do
    %{state | last_input_at_ms: System.monotonic_time(:millisecond)}
  end

  defp event_transition(state) do
    state = note_input(state)
    {:noreply, maybe_flush_pending_refresh(state)}
  end

  defp reset_content_scroll(state) do
    %{state | content_scroll_x: 0, content_scroll_y: 0, log_scroll: 0}
  end

  defp maybe_switch_to_apply_result(state, %{apply_result: nil}), do: state
  defp maybe_switch_to_apply_result(state, _payload), do: state

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

  defp modal_open?(state) do
    not is_nil(Map.get(state, :prompt)) or not is_nil(Map.get(state, :rollout_confirmation))
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
      "Targets:",
      Enum.join(hosts, "\n"),
      "",
      "Current live versions:",
      Enum.join(versions, "\n"),
      "",
      "Press u or enter to apply. Press esc to cancel."
    ]
    |> Enum.join("\n")
  end

  defp prompt_text(prompt) do
    [
      "#{prompt.label}:",
      prompt.value,
      "",
      "Press enter to confirm or esc to cancel."
    ]
    |> Enum.join("\n")
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

  defp rollout_version_rows(nil, _target_nodes), do: []

  defp rollout_version_rows(overview, []) do
    rollout_version_rows(overview, cluster_node_names(overview))
  end

  defp rollout_version_rows(overview, target_nodes) do
    target_nodes
    |> Enum.map(fn node_name ->
      node =
        case node_name do
          value when is_atom(value) -> value
          value -> String.to_atom(value)
        end

      version =
        overview
        |> node_status_for(node)
        |> case do
          nil -> "unknown"
          node_status -> Map.get(node_status, :version, "unknown")
        end

      {Atom.to_string(node), version}
    end)
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

  defp unpack_exit_action(_pending_action), do: nil
end
