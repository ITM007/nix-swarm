defmodule NixSwarm.TUI.State do
  @moduledoc "Construction of the single, read-only TUI operator state."

  alias NixSwarm.ConfigFiles

  @doc "Build the TUI state from the existing operator options and resume state."
  def new(opts, default_cluster_metrics) when is_list(opts) do
    resume_state = Keyword.get(opts, :resume_state, %{})

    %{
      remote: Keyword.fetch!(opts, :remote),
      lines: Keyword.get(opts, :lines, 50),
      refresh_ms: Keyword.get(opts, :refresh_ms, 30_000),
      active_view: :dashboard,
      selected_service: nil,
      selected_node: nil,
      update_fun: Keyword.get(opts, :update_fun, &NixSwarm.Update.run/2),
      diagnostic: nil,
      overview: nil,
      service_logs: [],
      cluster_logs: "",
      cluster_event_logs: "",
      log_scroll: 0,
      metrics_history: %{cpu: [], memory: [], disk: [], network: []},
      cluster_metrics: default_cluster_metrics,
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
      deploy_fun: Keyword.get(opts, :deploy_fun, &NixSwarm.Deploy.run/1),
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
    |> Map.put(:operator_mode, :read_only)
  end
end
