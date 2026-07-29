defmodule NixSwarmTUIInternalTest do
  use ExUnit.Case, async: false

  test "state construction preserves the read-only operator context and resume state" do
    state =
      NixSwarm.TUI.State.new(
        [
          remote: %{target: "node-a"},
          lines: 12,
          refresh_ms: 345,
          config_paths: %{machines: "machines.nix"},
          owner_pid: self(),
          test_pid: self(),
          resume_state: %{active_view: :services, flash: "resumed"}
        ],
        %{cpu: %{pct: 0}}
      )

    assert state.remote == %{target: "node-a"}
    assert state.lines == 12
    assert state.refresh_ms == 345
    assert state.config_paths == %{machines: "machines.nix"}
    assert state.owner_pid == self()
    assert state.test_pid == self()
    assert state.active_view == :services
    assert state.flash == "resumed"
    assert state.operator_mode == :read_only
    assert state.cluster_metrics == %{cpu: %{pct: 0}}
    assert state.metrics_history == %{cpu: [], memory: [], disk: [], network: []}

    for key <- [
          :update_fun,
          :deploy_fun,
          :rollout_confirmation,
          :action_confirmation,
          :pending_operator_action,
          :pending_machine_actions,
          :apply_result
        ] do
      refute Map.has_key?(state, key), "mutable state key #{inspect(key)} should not exist"
    end
  end

  test "runtime helpers preserve the TUI native-directory contract" do
    root = Path.join(System.tmp_dir!(), "nix-swarm-runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    app_dir = fn :ex_ratatui, "priv/native" -> root end
    assert NixSwarm.TUI.Runtime.supported?(app_dir)
    assert NixSwarm.TUI.runtime_supported?(app_dir)

    missing = Path.join(root, "missing")
    error = NixSwarm.TUI.Runtime.support_error(fn :ex_ratatui, "priv/native" -> missing end)

    assert error ==
             NixSwarm.TUI.runtime_support_error(fn :ex_ratatui, "priv/native" -> missing end)

    assert error =~ "expected ex_ratatui native directory"
  end
end
