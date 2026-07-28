defmodule NixSwarmProjectPolicyTest do
  use ExUnit.Case, async: true

  test "the project requires and enables Elixir 1.20 type inference" do
    project = Mix.Project.config()

    assert project[:elixir] == "~> 1.20"
    assert project[:elixirc_options][:infer_signatures]
    assert project[:test_elixirc_options][:infer_signatures]
    assert Version.match?(System.version(), project[:elixir])
  end

  test "coverage cannot silently fall below the established baseline" do
    project = Mix.Project.config()
    assert project[:test_coverage][:summary][:threshold] >= 65
  end

  test "the TUI and runtime API enforce the code-first mutation boundary" do
    assert NixSwarm.TUI.read_only?()
    refute function_exported?(NixSwarm.API, :start_service, 1)
    refute function_exported?(NixSwarm.API, :stop_service, 1)
    refute function_exported?(NixSwarm.API, :restart_machine, 1)
  end
end
