defmodule NixSwarmOperatorContextTest do
  use ExUnit.Case, async: true

  test "normalizes one shared operator context for CLI and TUI" do
    context =
      NixSwarm.OperatorContext.from_opts(
        source: "/tmp/project",
        target: "nix-swarm@node-a",
        ssh_host: "root@node-a",
        cluster_file: "/tmp/project/cluster.nix"
      )

    assert context.source == "/tmp/project"
    assert context.remote.target == "nix-swarm@node-a"
    assert context.remote.ssh_host == "root@node-a"
    assert context.paths.cluster_file == "/tmp/project/cluster.nix"
    assert context.read_only?
  end
end
