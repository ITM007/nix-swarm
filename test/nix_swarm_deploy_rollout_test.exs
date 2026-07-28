defmodule NixSwarmDeployRolloutTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Deploy.Rollout

  defp target(host, classification \\ nil) do
    %{
      host: host,
      configuration: String.replace(host, "root@", ""),
      classification: classification
    }
  end

  test "bootstraps new nodes before existing nodes" do
    targets = [
      target("root@node-b", :existing_outdated),
      target("root@node-c", :new_nixos_host),
      target("root@node-a", :existing_outdated)
    ]

    rollout = Rollout.plan(targets, max_unavailable: 1, canary_hosts: ["root@node-a"])

    assert Enum.map(rollout.bootstrap, & &1.host) == ["root@node-c"]
    assert Enum.map(rollout.existing, & &1.host) == ["root@node-a", "root@node-b"]

    assert Enum.map(rollout.stages, fn stage -> Enum.map(stage, & &1.host) end) == [
             ["root@node-c"],
             ["root@node-a"],
             ["root@node-b"]
           ]
  end

  test "classifications can be supplied separately from target metadata" do
    targets = [target("root@node-c"), target("root@node-a")]

    rollout =
      Rollout.plan(targets,
        classifications: %{
          "root@node-c" => :installed_inactive,
          "root@node-a" => :existing_in_sync
        },
        max_unavailable: 2
      )

    assert Enum.map(rollout.bootstrap, & &1.host) == ["root@node-c"]
    assert Enum.map(rollout.existing, & &1.host) == ["root@node-a"]
  end

  test "blocked targets fail before producing mutation stages" do
    assert_raise ArgumentError, ~r/blocked target/, fn ->
      Rollout.plan([target("root@node-c", :incompatible)])
    end
  end

  test "reports attempted and unattempted hosts by stage index" do
    stages = [[target("root@node-c")], [target("root@node-a")], [target("root@node-b")]]

    assert Rollout.attempted_hosts(stages, 2) == ["root@node-c", "root@node-a"]
    assert Rollout.unattempted_hosts(stages, 2) == ["root@node-b"]
  end

  test "Deploy exposes the pure rollout planner" do
    targets = [target("root@node-c", :new_nixos_host), target("root@node-a", :existing_in_sync)]

    rollout = NixSwarm.Deploy.rollout_plan(targets, max_unavailable: 1)

    assert Enum.map(rollout.bootstrap, & &1.host) == ["root@node-c"]
    assert Enum.map(rollout.existing, & &1.host) == ["root@node-a"]
  end
end
