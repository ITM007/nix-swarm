defmodule NixSwarmPlacementTest do
  use ExUnit.Case, async: true

  test "placement is deterministic and honors constraints" do
    config =
      NixSwarm.Config.normalize(%{
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
    plan_a = NixSwarm.Placement.plan(config, live_nodes)
    plan_b = NixSwarm.Placement.plan(config, live_nodes)

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
      Path.join(
        System.tmp_dir!(),
        "nix-swarm-config-#{System.unique_integer([:positive])}.config"
      )

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

    config = path |> NixSwarm.Config.load_from_path() |> NixSwarm.Config.normalize()

    assert config.peers == [:"node-a@127.0.0.1", :"node-b@127.0.0.1"]
    assert length(config.services) == 1
    assert hd(config.services).name == "gitea"
    assert hd(config.services).settings == %{}

    File.rm_rf!(path)
  end

  test "service settings are preserved" do
    config =
      NixSwarm.Config.normalize(%{
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

  test "service settings loaded from erlang charlists are normalized" do
    path =
      Path.join(
        System.tmp_dir!(),
        "nix-swarm-settings-#{System.unique_integer([:positive])}.config"
      )

    File.write!(
      path,
      """
      {services, [[
        {name, "gitea"},
        {settings, [{domain, "gitea.home"}, {http_port, 3000}]}
      ]]}.
      """
    )

    config = path |> NixSwarm.Config.load_from_path() |> NixSwarm.Config.normalize()

    assert hd(config.services).settings == %{domain: "gitea.home", http_port: 3000}

    File.rm_rf!(path)
  end

  test "service defaults derive the unit template from the replica count" do
    single =
      NixSwarm.Config.normalize(%{
        services: [
          %{name: "gitea"}
        ]
      })
      |> Map.fetch!(:services)
      |> hd()

    multi =
      NixSwarm.Config.normalize(%{
        services: [
          %{name: "gitea", replicas: 2}
        ]
      })
      |> Map.fetch!(:services)
      |> hd()

    assert single.unit_template == "%{service}.service"
    assert multi.unit_template == "%{service}@%{slot}.service"
  end

  test "placement prefers configured machines before reusing other eligible nodes" do
    config =
      NixSwarm.Config.normalize(%{
        peers: [:"node-a@127.0.0.1", :"node-b@127.0.0.1", :"node-c@127.0.0.1"],
        nodes: %{
          :"node-a@127.0.0.1" => %{labels: ["gitea"]},
          :"node-b@127.0.0.1" => %{labels: ["gitea"]},
          :"node-c@127.0.0.1" => %{labels: ["gitea"]}
        },
        services: [
          %{
            name: "gitea",
            replicas: 2,
            unit_template: "gitea.service",
            constraints: ["gitea"],
            preferred_nodes: [:"node-c@127.0.0.1", :"node-a@127.0.0.1"]
          }
        ]
      })

    owners =
      config
      |> NixSwarm.Placement.plan(config.peers)
      |> Map.fetch!("gitea")
      |> Enum.map(& &1.owner)

    assert owners == [:"node-c@127.0.0.1", :"node-a@127.0.0.1"]
  end

  test "placement diagnostics explain unowned and underspread services" do
    config =
      NixSwarm.Config.normalize(%{
        peers: [:"node-a@127.0.0.1", :"node-b@127.0.0.1"],
        nodes: %{
          :"node-a@127.0.0.1" => %{labels: ["ssd"]},
          :"node-b@127.0.0.1" => %{labels: ["edge"]}
        },
        services: [
          %{name: "db", replicas: 2, constraints: ["ssd"]},
          %{name: "gpu", replicas: 1, constraints: ["gpu"]}
        ]
      })

    diagnostics = NixSwarm.Placement.diagnostics(config, [:"node-a@127.0.0.1"])

    assert Enum.any?(
             diagnostics,
             &match?(%{service: "db", reason: :replicas_exceed_live_eligible_nodes}, &1)
           )

    assert Enum.any?(
             diagnostics,
             &match?(%{service: "gpu", reason: :no_configured_eligible_nodes}, &1)
           )

    assert Enum.any?(
             diagnostics,
             &match?(%{service: "gpu", reason: :unowned_slots, slots: [0]}, &1)
           )
  end
end
