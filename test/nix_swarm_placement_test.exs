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

    {:ok, raw} = NixSwarm.Config.load_from_path(path)
    config = NixSwarm.Config.normalize(raw)

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
            settings: %{domain: "gitea.example.internal", http_port: 3000}
          }
        ]
      })

    assert hd(config.services).settings == %{domain: "gitea.example.internal", http_port: 3000}
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
        {settings, [{domain, "gitea.example.internal"}, {http_port, 3000}]}
      ]]}.
      """
    )

    {:ok, raw} = NixSwarm.Config.load_from_path(path)
    config = NixSwarm.Config.normalize(raw)

    assert hd(config.services).settings == %{domain: "gitea.example.internal", http_port: 3000}

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

  test "allowed nodes are a hard filter before preferred node ordering" do
    config =
      NixSwarm.Config.normalize(%{
        peers: [:"node-a@127.0.0.1", :"node-b@127.0.0.1", :"node-c@127.0.0.1"],
        nodes: %{
          :"node-a@127.0.0.1" => %{labels: ["apps"]},
          :"node-b@127.0.0.1" => %{labels: ["apps"]},
          :"node-c@127.0.0.1" => %{labels: ["apps"]}
        },
        services: [
          %{
            name: "api",
            replicas: 2,
            constraints: ["apps"],
            allowed_nodes: [:"node-a@127.0.0.1", :"node-b@127.0.0.1"],
            preferred_nodes: [:"node-c@127.0.0.1", :"node-b@127.0.0.1"]
          }
        ]
      })

    owners =
      config
      |> NixSwarm.Placement.plan(config.peers)
      |> Map.fetch!("api")
      |> Enum.map(& &1.owner)

    assert owners == [:"node-b@127.0.0.1", :"node-a@127.0.0.1"]
  end

  test "declaratively draining a node removes it from placement" do
    node_a = :"node-a@127.0.0.1"
    node_b = :"node-b@127.0.0.1"

    config =
      NixSwarm.Config.normalize(%{
        peers: [node_a, node_b],
        nodes: %{
          node_a => %{labels: ["apps"], availability: :draining},
          node_b => %{labels: ["apps"], availability: :active}
        },
        services: [%{name: "api", replicas: 1, constraints: ["apps"]}]
      })

    assert [%{owner: ^node_b}] = NixSwarm.Placement.plan(config, config.peers)["api"]
    assert config.nodes[node_a].availability == :draining
  end

  test "zero replicas disables placement without a diagnostic" do
    config =
      NixSwarm.Config.normalize(%{
        peers: [:"node-a@127.0.0.1"],
        nodes: %{:"node-a@127.0.0.1" => %{labels: ["apps"]}},
        services: [%{name: "api", replicas: 0, constraints: ["apps"]}]
      })

    assert NixSwarm.Placement.plan(config, config.peers)["api"] == []
    refute Enum.any?(NixSwarm.Placement.diagnostics(config, config.peers), &(&1.service == "api"))
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

  test "owner_for_slot cycles through ranked nodes" do
    nodes = [:a@x, :b@x, :c@x]

    assert NixSwarm.Placement.owner_for_slot(nodes, 0) == :a@x
    assert NixSwarm.Placement.owner_for_slot(nodes, 1) == :b@x
    assert NixSwarm.Placement.owner_for_slot(nodes, 2) == :c@x
    assert NixSwarm.Placement.owner_for_slot(nodes, 3) == :a@x
    assert NixSwarm.Placement.owner_for_slot(nodes, 4) == :b@x
  end

  test "owner_for_slot returns nil for empty node list" do
    assert NixSwarm.Placement.owner_for_slot([], 0) == nil
    assert NixSwarm.Placement.owner_for_slot([], 5) == nil
  end

  test "local_units filters to only the given node" do
    config =
      NixSwarm.Config.normalize(%{
        peers: [:"node-a@127.0.0.1", :"node-b@127.0.0.1"],
        nodes: %{
          :"node-a@127.0.0.1" => %{labels: ["apps"]},
          :"node-b@127.0.0.1" => %{labels: ["apps"]}
        },
        services: [
          %{name: "api", replicas: 2, constraints: ["apps"]}
        ]
      })

    units_a = NixSwarm.Placement.local_units(:"node-a@127.0.0.1", config, config.peers)
    units_b = NixSwarm.Placement.local_units(:"node-b@127.0.0.1", config, config.peers)

    assert length(units_a) == 1
    assert hd(units_a).service == "api"

    assert length(units_b) == 1
    assert hd(units_b).service == "api"

    assert units_a != units_b
  end

  test "local_units returns empty list for a node that owns nothing" do
    config =
      NixSwarm.Config.normalize(%{
        peers: [:"node-a@127.0.0.1", :"node-b@127.0.0.1"],
        nodes: %{
          :"node-a@127.0.0.1" => %{labels: ["apps"]},
          :"node-b@127.0.0.1" => %{labels: ["apps"]}
        },
        services: [
          %{name: "api", replicas: 1, constraints: ["apps"]}
        ]
      })

    plan = NixSwarm.Placement.plan(config, config.peers)
    owner = plan["api"] |> hd() |> Map.fetch!(:owner)
    non_owner = Enum.find(config.peers, &(&1 != owner))

    units = NixSwarm.Placement.local_units(non_owner, config, config.peers)
    assert units == []
  end

  test "placement wraps replicas around when there are more replicas than eligible nodes" do
    config =
      NixSwarm.Config.normalize(%{
        peers: [:"node-a@127.0.0.1", :"node-b@127.0.0.1"],
        nodes: %{
          :"node-a@127.0.0.1" => %{labels: ["apps"]},
          :"node-b@127.0.0.1" => %{labels: ["apps"]}
        },
        services: [
          %{name: "api", replicas: 4, constraints: ["apps"]}
        ]
      })

    owners =
      config
      |> NixSwarm.Placement.plan(config.peers)
      |> Map.fetch!("api")
      |> Enum.map(& &1.owner)

    assert length(owners) == 4
    # With 2 eligible nodes and 4 replicas, each node should own 2 slots
    assert Enum.count(owners, &(&1 == :"node-a@127.0.0.1")) == 2
    assert Enum.count(owners, &(&1 == :"node-b@127.0.0.1")) == 2
  end

  test "autoscaled placement stays inside code-defined per-node capacity" do
    nodes = [:"node-a@127.0.0.1", :"node-b@127.0.0.1"]

    config =
      NixSwarm.Config.normalize(%{
        peers: nodes,
        nodes: Map.new(nodes, &{&1, %{labels: ["apps"]}}),
        services: [
          %{
            name: "api",
            replicas: 2,
            constraints: ["apps"],
            max_replicas_per_node: 2,
            autoscaling: %{enable: true, minReplicas: 2, maxReplicas: 5}
          }
        ]
      })

    slots = NixSwarm.Placement.plan(config, nodes, %{"api" => 5})["api"]
    owners = Enum.map(slots, & &1.owner)

    assert length(slots) == 5
    assert Enum.count(owners, &(&1 == hd(nodes))) <= 2
    assert Enum.count(owners, &(&1 == List.last(nodes))) <= 2
    assert Enum.count(owners, &is_nil/1) == 1
  end

  test "diagnostics reports invalid replica count" do
    config =
      NixSwarm.Config.normalize(%{
        peers: [:"node-a@127.0.0.1"],
        nodes: %{:"node-a@127.0.0.1" => %{labels: ["apps"]}},
        services: [%{name: "api", replicas: -1, constraints: ["apps"]}]
      })

    diagnostics = NixSwarm.Placement.diagnostics(config, config.peers)
    assert Enum.any?(diagnostics, &match?(%{service: "api", reason: :invalid_replica_count}, &1))
  end
end
