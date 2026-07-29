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

  test "the public CLI contract is intentionally small" do
    help = capture_help()

    for command <- [
          "cluster plan",
          "cluster apply",
          "cluster rollback",
          "cluster upgrade",
          "cluster credentials rotate",
          "cluster doctor",
          "cluster status",
          "service logs",
          "service restart"
        ] do
      assert help =~ command, "supported command missing from help: #{command}"
    end

    for removed <- [
          "cluster init",
          "cluster ensure",
          "cluster rebuild",
          "cluster members",
          "cluster upgrade prepare",
          "service create",
          "service add",
          "service list"
        ] do
      refute help =~ removed, "removed command still advertised: #{removed}"
    end
  end

  test "Caddy routing is Nix-defined and has no mutable runtime control path" do
    cluster = File.read!("examples/config/cluster/cluster.nix")
    edge = File.read!("examples/config/services/caddy-edge.nix")

    runtime =
      Path.wildcard("lib/nix_swarm/**/*.ex")
      |> Enum.map_join("\\n", &File.read!/1)

    assert cluster =~ ~s(unitTemplate = "caddy.service")
    assert cluster =~ ~s(allowedNodes = [ "nix-swarm@example-node-a.local" ])
    assert edge =~ "services.caddy"
    assert edge =~ "reverse_proxy"
    assert edge =~ "health_uri"
    assert edge =~ "health_interval"

    refute runtime =~ "Caddyfile"
    refute runtime =~ "caddy reload"
    refute runtime =~ "/config/apps/http"
    refute runtime =~ "localhost:2019"
  end

  test "the multi-node example uses only the current service schema" do
    cluster = File.read!("examples/config/cluster/cluster.nix")

    for forbidden <- ["labels", "preferredNodes", "constraints", "maxReplicasPerNode"] do
      refute cluster =~ forbidden
    end

    assert cluster =~ ~s(unitTemplate = "example-web@%{slot}.service")
    assert cluster =~ "allowedNodes"
  end

  test "the Nix module does not expose compatibility or rollout tuning options" do
    module = File.read!("nix/nix-swarm/module.nix")

    for forbidden <- [
          "ingress",
          "healthcheck",
          "settings",
          "preferredNodes",
          "labels",
          "constraints",
          "maxReplicasPerNode",
          "readiness",
          "sampleWindowSec",
          "scaleUpCooldownSec",
          "scaleDownCooldownSec",
          "maxStep",
          "connectIntervalMs",
          "reconcileIntervalMs",
          "autoscaleIntervalMs",
          "failureGraceMs",
          "recoveryStabilizationMs",
          "commandTimeoutMs",
          "generation",
          "healthTimeoutSec",
          "stableSamples",
          "canaryNodes",
          "maxUnavailable",
          "autoRollback"
        ] do
      refute Regex.match?(~r/\b#{Regex.escape(forbidden)}\b/, module),
             "#{forbidden} must not be a public Nix option"
    end

    for forbidden <- [
          "connect_interval_ms",
          "reconcile_interval_ms",
          "autoscale_interval_ms",
          "failure_grace_ms",
          "recovery_stabilization_ms",
          "command_timeout_ms"
        ] do
      refute module =~ forbidden, "#{forbidden} must not be emitted in the generated manifest"
    end
  end

  defp capture_help do
    ExUnit.CaptureIO.capture_io(fn -> assert :ok == NixSwarm.CLI.run(["help"]) end)
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

  test "the starter contains only prepared-machine Nix configuration" do
    starter = Path.expand("../examples/starter", __DIR__)
    flake = File.read!(Path.join(starter, "flake.nix"))
    readme = File.read!(Path.join(starter, "README.md"))

    refute flake =~ "disko"
    refute flake =~ "nixos-anywhere"
    refute readme =~ "nixos-anywhere"
    refute readme =~ "Disko"
    refute File.exists?(Path.join(starter, "disko"))
    refute File.exists?(Path.join(starter, "machines/node-c"))
    refute File.exists?(Path.join(starter, "machines/hardened-node.nix"))

    assert flake =~ "node-a"
    assert readme =~ "already running NixOS"
    assert File.exists?(Path.join(starter, "services/example-web.nix"))
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
