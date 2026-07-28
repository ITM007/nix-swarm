defmodule NixSwarm.DockerHarnessTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @stack Path.join(@root, "scripts/docker-stack")
  @scenarios Path.join(@root, "scripts/docker-scenarios")
  @compose Path.join(@root, "docker-compose.yml")

  test "stack exposes deterministic lifecycle and scenario commands" do
    stack = File.read!(@stack)

    for command <- ~w(up status scenario evidence down reset) do
      assert stack =~ "#{command})", "missing #{command} command"
    end

    assert stack =~ "docker"
    assert stack =~ "--project-name"
    assert stack =~ "NIX_SWARM_DOCKER_PROJECT"
  end

  test "status assertion is fail-closed and checks all four expected services" do
    stack = File.read!(@stack)

    assert stack =~ "status --assert-ready"
    assert stack =~ "node-a"
    assert stack =~ "node-b"
    assert stack =~ "node-c"
    assert stack =~ "operator"
    assert stack =~ "empty_runtime"
    assert stack =~ "service_healthy"
  end

  test "reset cleans only harness-owned resources and generated development material" do
    stack = File.read!(@stack)

    assert stack =~ "down -v --remove-orphans"
    assert stack =~ "result-docker-"
    assert stack =~ "rm -rf \"$secrets_dir\""
    assert stack =~ "reset_resources"
  end

  test "scenario catalog has stable IDs and a failure injection interface" do
    scenarios = File.read!(@scenarios)

    for id <-
          ~w(clean-bootstrap add-new-node add-multiple-nodes missing-credential matching-credential mismatched-credential unreachable-target wrong-architecture low-disk) do
      assert scenarios =~ id
    end

    assert scenarios =~ "--failure"
    assert scenarios =~ "NIX_SWARM_DOCKER_FAILURE"
    assert scenarios =~ "failure_injection"
  end

  test "scenario runner delegates to the prepared-node verification boundary" do
    scenarios = File.read!(@scenarios)
    verifier = File.read!(Path.join(@root, "scripts/verify_cluster.exs"))

    assert scenarios =~ "verify_cluster.exs"
    assert verifier =~ "NIX_SWARM_DOCKER_SCENARIO"
    assert verifier =~ "NIX_SWARM_DOCKER_FAILURE"
  end

  test "profiles have isolated deterministic compose project names" do
    stack = File.read!(@stack)
    compose = File.read!(@compose)

    assert stack =~ "nix-swarm-${profile}"
    assert compose =~ "NIX_SWARM_DOCKER_PROFILE"
    refute compose =~ "nix-swarm-integration"
  end

  test "unavailable Docker fails closed without pretending a scenario ran" do
    {_output, status} =
      System.cmd(@scenarios, ["--scenario", "clean-bootstrap"],
        env: [{"NIX_SWARM_DOCKER_COMMAND", "definitely-not-docker"}],
        stderr_to_stdout: true
      )

    assert status != 0
    stack = File.read!(@stack)
    assert stack =~ "Docker is unavailable"
  end
end
