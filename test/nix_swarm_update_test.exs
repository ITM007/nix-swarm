defmodule NixSwarmUpdateTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Update

  @source Path.expand("..", __DIR__)

  test "detects version and membership changes" do
    refute Update.versions_changed?(%{"a" => "1"}, %{"a" => "1"})
    assert Update.versions_changed?(%{"a" => "1"}, %{"a" => "2"})
    assert Update.versions_changed?(%{"a" => "1"}, %{"a" => "1", "b" => "1"})
    assert Update.versions_changed?(%{}, %{"a" => "1"})
  end

  test "derives rollout hosts, nodes, and configurations from cluster state" do
    node_a = :"node-a@example.test"
    node_b = :"node-b@example.test"

    cluster_state = %{
      overview: %{
        members: %{
          live_nodes: [node_a, node_b],
          deploy_hosts: %{node_a => "root@node-a", node_b => "root@node-b"},
          deploy_configurations: %{node_a => "node-a", node_b => "node-b"}
        }
      }
    }

    assert Update.target_hosts(cluster_state) == ["root@node-a", "root@node-b"]

    assert Update.target_nodes(cluster_state, ["root@node-b"]) == [
             "node-b@example.test"
           ]

    opts = Update.effective_deploy_opts([source: @source], cluster_state)
    assert opts[:hosts] == ["root@node-a", "root@node-b"]
    assert opts[:configurations] == %{node_a => "node-a", node_b => "node-b"}
  end

  test "requires all expected nodes and one converged version" do
    refute Update.rollout_report_ready?(%{}, %{}, [])
    refute Update.rollout_report_ready?(%{}, %{"a" => "1"}, ["a", "b"])
    refute Update.rollout_report_ready?(%{}, %{"a" => "1", "b" => "2"}, ["a", "b"])
    assert Update.rollout_report_ready?(%{}, %{"a" => "2", "b" => "2"}, ["a", "b"])
  end

  test "dry-run update returns a complete rollout report without RPC" do
    deploy_fun = fn opts ->
      %{dry_run: Keyword.fetch!(opts, :dry_run), results: [], hosts: opts[:hosts]}
    end

    report =
      Update.run(
        [
          source: @source,
          hosts: ["root@example-node-a.local"],
          configurations: %{"root@example-node-a.local" => "node-a"},
          target_nodes: ["node-a"],
          dry_run: true
        ],
        nil,
        deploy_fun
      )

    assert report.deploy.dry_run
    assert report.target_hosts == ["root@example-node-a.local"]
    assert report.target_nodes == ["node-a"]
    assert report.before_versions == %{}
    assert report.after_versions == %{}
    refute report.version_changed?
    assert is_binary(report.completed_at)
  end
end
