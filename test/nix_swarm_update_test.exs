defmodule NixSwarmUpdateTest do
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

    opts = NixSwarm.Update.effective_deploy_opts([source: "."], cluster_state)

    assert Keyword.get(opts, :hosts) == ["root@node-a", "root@node-c"]
  end

  test "target hosts accept string deploy-host keys from cluster overviews" do
    cluster_state = %{
      overview: %{
        members: %{
          live_nodes: [:"node-a@127.0.0.1", :"node-c@127.0.0.1"],
          deploy_hosts: %{
            "node-a@127.0.0.1" => "root@node-a",
            "node-b@127.0.0.1" => "root@node-b",
            "node-c@127.0.0.1" => "root@node-c"
          }
        }
      }
    }

    assert NixSwarm.Update.target_hosts(cluster_state) == ["root@node-a", "root@node-c"]
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
      NixSwarm.Update.effective_deploy_opts([source: ".", hosts: ["root@manual"]], cluster_state)

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

    assert NixSwarm.Update.target_nodes(cluster_state, ["root@node-b"]) == ["node-b@127.0.0.1"]
  end

  test "target nodes accept string node keys from cluster overviews" do
    cluster_state = %{
      overview: %{
        members: %{
          deploy_hosts: %{
            "node-a@127.0.0.1" => "root@node-a",
            "node-b@127.0.0.1" => "root@node-b"
          }
        }
      }
    }

    assert NixSwarm.Update.target_nodes(cluster_state, ["root@node-b"]) == ["node-b@127.0.0.1"]
  end

  test "rollout report waits for every expected node to converge to one version" do
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

    refute NixSwarm.Update.rollout_report_ready?(
             before_versions,
             partial_after,
             Map.keys(before_versions)
           )

    assert NixSwarm.Update.rollout_report_ready?(
             before_versions,
             full_after,
             Map.keys(before_versions)
           )
  end

  test "rollout report accepts a single targeted node once it comes back" do
    before_versions = %{"node-a@127.0.0.1" => "v0.1.0-old"}

    after_versions = %{
      "node-a@127.0.0.1" => "v0.1.0-new",
      "node-b@127.0.0.1" => "v0.1.0-old"
    }

    assert NixSwarm.Update.rollout_report_ready?(before_versions, after_versions, [
             "node-a@127.0.0.1"
           ])
  end
end
