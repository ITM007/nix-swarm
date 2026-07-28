defmodule NixSwarmProjectPolicyTest do
  use ExUnit.Case, async: true
  import Bitwise

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

  test "canonical onboarding starts with a prepared NixOS machine" do
    docs = [
      "README.md",
      "AGENT.md",
      "docs/BOOTSTRAP.md",
      "docs/PROVISIONING.md",
      "docs/OPERATIONS.md",
      "docs/TESTING.md",
      "examples/starter/README.md"
    ]

    assert Enum.all?(docs, &File.exists?/1), "missing canonical onboarding document"
    text = docs |> Enum.map(&File.read!/1) |> Enum.join("\\n")

    assert text =~ "already running NixOS"

    for prerequisite <- ["SSH", "privilege", "architecture", "disk", "private network", ".nix"] do
      assert text =~ prerequisite, "onboarding must name #{prerequisite} as a prerequisite"
    end

    assert text =~ "cluster apply"
    assert text =~ "first Nix-Swarm mutation"

    refute Regex.match?(~r/production (?:ready|readiness).*bare.?metal/i, text)
    refute Regex.match?(~r/(?:release|product) (?:requirement|gate).*nixos-anywhere/i, text)
    refute Regex.match?(~r/(?:release|product) (?:requirement|gate).*Disko/i, text)
  end

  test "the old roadmap preserves the prepared-host release boundary" do
    roadmap = File.read!(".hermes/plans/2026-07-28_163547-code-first-bootstrap-upgrade-final.md")

    assert roadmap =~ "begins at SSH/preflight"
    assert roadmap =~ "Prepared-NixOS"
    assert roadmap =~ "not a Nix-Swarm release gate"
    refute roadmap =~ "Turnkey NixOS provisioning profile"
    refute roadmap =~ "Nix-Swarm must ship a tested starter profile"
  end

  test "release orchestration is an explicit clean-checkout command" do
    assert File.regular?("scripts/release-check")
    assert (File.stat!("scripts/release-check").mode &&& 0o111) != 0
    script = File.read!("scripts/release-check")
    assert script =~ "git worktree add --detach"
    assert script =~ "trap cleanup EXIT"
    assert script =~ "docker compose"
    assert File.read!("docs/RELEASE.md") =~ "prepared NixOS"
  end
end
