defmodule NixSwarmPlacementTest do
  use ExUnit.Case, async: true

  test "placement is deterministic and spreads across active nodes" do
    config =
      NixSwarm.Config.normalize(%{
        peers: [:"node-a@127.0.0.1", :"node-b@127.0.0.1", :"node-c@127.0.0.1"],
        nodes: %{},
        services: [%{name: "proxy", replicas: 1}, %{name: "gitea", replicas: 2}]
      })

    assert NixSwarm.Placement.plan(config, config.peers) ==
             NixSwarm.Placement.plan(config, config.peers)

    owners = Enum.map(NixSwarm.Placement.plan(config, config.peers)["gitea"], & &1.owner)
    assert Enum.all?(owners, &(&1 in config.peers))
    assert length(Enum.uniq(owners)) == 2
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
    refute Map.has_key?(hd(config.services), :settings)

    File.rm_rf!(path)
  end

  test "compatibility-only service metadata is omitted during normalization" do
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

    refute Map.has_key?(hd(config.services), :settings)
    refute Map.has_key?(hd(config.services), :healthcheck)
  end

  test "compatibility-only service metadata loaded from erlang terms is omitted" do
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

    refute Map.has_key?(hd(config.services), :settings)
    refute Map.has_key?(hd(config.services), :healthcheck)

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

  test "allowed nodes are a hard filter" do
    config =
      NixSwarm.Config.normalize(%{
        peers: [:"node-a@127.0.0.1", :"node-b@127.0.0.1", :"node-c@127.0.0.1"],
        nodes: %{},
        services: [
          %{name: "api", replicas: 2, allowed_nodes: [:"node-a@127.0.0.1", :"node-b@127.0.0.1"]}
        ]
      })

    owners = Enum.map(NixSwarm.Placement.plan(config, config.peers)["api"], & &1.owner)
    assert Enum.all?(owners, &(&1 in [:"node-a@127.0.0.1", :"node-b@127.0.0.1"]))
  end

  test "declaratively draining a node removes it from placement" do
    node_a = :"node-a@127.0.0.1"
    node_b = :"node-b@127.0.0.1"

    config =
      NixSwarm.Config.normalize(%{
        peers: [node_a, node_b],
        nodes: %{node_a => %{availability: :draining}, node_b => %{availability: :active}},
        services: [%{name: "api", replicas: 1}]
      })

    assert [%{owner: ^node_b}] = NixSwarm.Placement.plan(config, config.peers)["api"]
    assert config.nodes[node_a].availability == :draining
  end

  test "maintenance nodes are excluded from placement" do
    node_a = :"node-a@127.0.0.1"
    node_b = :"node-b@127.0.0.1"

    config =
      NixSwarm.Config.normalize(%{
        peers: [node_a, node_b],
        nodes: %{node_a => %{availability: :maintenance}, node_b => %{availability: :active}},
        services: [%{name: "api", replicas: 1}]
      })

    assert [%{owner: ^node_b}] = NixSwarm.Placement.plan(config, config.peers)["api"]
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
          %{name: "db", replicas: 2},
          %{name: "gpu", replicas: 1, allowed_nodes: [:"missing@127.0.0.1"]}
        ]
      })

    diagnostics = NixSwarm.Placement.diagnostics(config, [:"node-a@127.0.0.1"])

    assert Enum.any?(
             diagnostics,
             &match?(%{service: "db", reason: :replicas_exceed_live_eligible_nodes}, &1)
           )

    assert Enum.any?(
             diagnostics,
             &match?(%{service: "gpu", reason: :no_eligible_nodes}, &1)
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

  test "autoscaled placement cycles without per-node capacity limits" do
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
    assert Enum.sort(Enum.frequencies(owners) |> Map.values()) == [2, 3]
    refute Enum.any?(owners, &is_nil/1)
  end

  test "normalized services expose only allowed node placement metadata" do
    service =
      NixSwarm.Config.normalize(%{
        services: [
          %{
            name: "api",
            replicas: 1,
            constraints: ["apps"],
            preferredNodes: [:"bad@127.0.0.1"],
            maxReplicasPerNode: 2
          }
        ]
      })
      |> Map.fetch!(:services)
      |> hd()

    assert service.allowed_nodes == []
    refute Map.has_key?(service, :constraints)
    refute Map.has_key?(service, :preferred_nodes)
    refute Map.has_key?(service, :max_replicas_per_node)
  end

  test "unknown allowed node leaves slots unassigned" do
    config =
      NixSwarm.Config.normalize(%{
        peers: [:"node-a@127.0.0.1"],
        services: [%{name: "api", replicas: 1, allowed_nodes: [:"missing@127.0.0.1"]}]
      })

    assert [%{owner: nil}] = NixSwarm.Placement.plan(config, config.peers)["api"]
  end

  test "diagnostics report no eligible nodes without constraints" do
    config =
      NixSwarm.Config.normalize(%{
        peers: [:"node-a@127.0.0.1"],
        services: [%{name: "api", replicas: 1, allowed_nodes: [:"missing@127.0.0.1"]}]
      })

    assert Enum.any?(
             NixSwarm.Placement.diagnostics(config, config.peers),
             &match?(%{reason: :no_eligible_nodes}, &1)
           )
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
