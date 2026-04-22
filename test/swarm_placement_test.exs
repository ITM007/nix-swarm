defmodule SwarmPlacementTest do
  use ExUnit.Case, async: true

  test "placement is deterministic and honors constraints" do
    config =
      Swarm.Config.normalize(%{
        peers: [:"node-a@127.0.0.1", :"node-b@127.0.0.1", :"node-c@127.0.0.1"],
        nodes: %{
          :"node-a@127.0.0.1" => %{labels: ["ssd", "edge"]},
          :"node-b@127.0.0.1" => %{labels: ["ssd"]},
          :"node-c@127.0.0.1" => %{labels: ["edge"]}
        },
        services: [
          %{
            name: "proxy",
            replicas: 1,
            unit_template: "proxy@%{slot}.service",
            constraints: ["edge"]
          },
          %{
            name: "gitea",
            replicas: 2,
            unit_template: "gitea@%{slot}.service",
            constraints: ["ssd"]
          }
        ]
      })

    live_nodes = config.peers
    plan_a = Swarm.Placement.plan(config, live_nodes)
    plan_b = Swarm.Placement.plan(config, live_nodes)

    assert plan_a == plan_b

    proxy_owner = plan_a["proxy"] |> hd() |> Map.fetch!(:owner)
    assert proxy_owner in [:"node-a@127.0.0.1", :"node-c@127.0.0.1"]

    gitea_owners =
      plan_a["gitea"]
      |> Enum.map(& &1.owner)

    assert Enum.all?(gitea_owners, &(&1 in [:"node-a@127.0.0.1", :"node-b@127.0.0.1"]))
  end

  test "config files can be loaded from erlang terms" do
    path =
      Path.join(System.tmp_dir!(), "swarm-config-#{System.unique_integer([:positive])}.config")

    File.write!(
      path,
      """
      {peers, ['node-a@127.0.0.1', 'node-b@127.0.0.1']}.
      {nodes, [
        {'node-a@127.0.0.1', [{labels, ["edge"]}]},
        {'node-b@127.0.0.1', [{labels, ["ssd"]}]}
      ]}.
      {services, [[
        {name, "gitea"},
        {replicas, 2},
        {unit_template, "gitea@%{slot}.service"}
      ]]}.
      """
    )

    config = path |> Swarm.Config.load_from_path() |> Swarm.Config.normalize()

    assert config.peers == [:"node-a@127.0.0.1", :"node-b@127.0.0.1"]
    assert length(config.services) == 1
    assert hd(config.services).name == "gitea"
    assert hd(config.services).settings == %{}

    File.rm_rf!(path)
  end

  test "service settings are preserved" do
    config =
      Swarm.Config.normalize(%{
        services: [
          %{
            name: "gitea",
            replicas: 1,
            settings: %{domain: "gitea.home", http_port: 3000}
          }
        ]
      })

    assert hd(config.services).settings == %{domain: "gitea.home", http_port: 3000}
  end
end
