defmodule NixSwarmDeployPlanTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Deploy.Plan

  test "fingerprint is deterministic and plan rendering excludes secret material" do
    deploy = %{
      source: "/tmp/nix-swarm-plan",
      cluster_file: "/tmp/nix-swarm-plan/cluster.nix",
      deployment_manifest: %{"nodes" => %{}},
      validation: %{targets: ["node-c"]},
      bootstrap_hosts: ["root@node-c"],
      existing_hosts: ["root@node-a"],
      batches: [[%{host: "root@node-c"}], [%{host: "root@node-a"}]],
      health_timeout_sec: 180,
      health_stable_samples: 3,
      auto_rollback: true
    }

    plan = Plan.build(deploy)

    assert plan.fingerprint == Plan.fingerprint(deploy)
    assert plan.rollout_stages == [["root@node-c"], ["root@node-a"]]
    refute String.contains?(Plan.render(plan), "cookie")
    refute String.contains?(Plan.render(plan), "secret")
  end
end
