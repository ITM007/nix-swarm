defmodule SwarmUpdateTest do
  use ExUnit.Case, async: true

  test "effective deploy opts target live node deploy hosts when available" do
    cluster_state = %{
      overview: %{
        members: %{
          live_nodes: [:"node-a@127.0.0.1", :"node-c@127.0.0.1"],
          deploy_hosts: %{
            :"node-a@127.0.0.1" => "root@node-a",
            :"node-b@127.0.0.1" => "root@node-b",
            :"node-c@127.0.0.1" => "root@node-c"
          }
        }
      }
    }

    opts = Swarm.Update.effective_deploy_opts([source: "."], cluster_state)

    assert Keyword.get(opts, :hosts) == ["root@node-a", "root@node-c"]
  end

  test "explicit hosts override live node deploy host targeting" do
    cluster_state = %{
      overview: %{
        members: %{
          live_nodes: [:"node-a@127.0.0.1"],
          deploy_hosts: %{:"node-a@127.0.0.1" => "root@node-a"}
        }
      }
    }

    opts =
      Swarm.Update.effective_deploy_opts([source: ".", hosts: ["root@manual"]], cluster_state)

    assert Keyword.get(opts, :hosts) == ["root@manual"]
  end

  test "target nodes follow resolved rollout hosts" do
    cluster_state = %{
      overview: %{
        members: %{
          live_nodes: [:"node-a@127.0.0.1", :"node-b@127.0.0.1"],
          deploy_hosts: %{
            :"node-a@127.0.0.1" => "root@node-a",
            :"node-b@127.0.0.1" => "root@node-b"
          }
        }
      }
    }

    assert Swarm.Update.target_nodes(cluster_state, ["root@node-b"]) == ["node-b@127.0.0.1"]
  end

  test "rollout report waits for every expected node once versions start changing" do
    before_versions = %{
      "node-a@127.0.0.1" => "v0.1.0-old",
      "node-b@127.0.0.1" => "v0.1.0-old"
    }

    partial_after = %{
      "node-a@127.0.0.1" => "v0.1.0-new",
      "node-b@127.0.0.1" => "v0.1.0-old"
    }

    full_after = %{
      "node-a@127.0.0.1" => "v0.1.0-new",
      "node-b@127.0.0.1" => "v0.1.0-new"
    }

    refute Swarm.Update.rollout_report_ready?(
             before_versions,
             partial_after,
             Map.keys(before_versions)
           )

    assert Swarm.Update.rollout_report_ready?(
             before_versions,
             full_after,
             Map.keys(before_versions)
           )
  end
end
