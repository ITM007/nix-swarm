defmodule NixSwarmDeployTest do
  use ExUnit.Case, async: true

  test "hosts parses comma-separated host list" do
    source = Path.expand("..", __DIR__)

    assert NixSwarm.Deploy.hosts([hosts: "example-node-a, root@example-node-b ,10.0.0.9"], source) ==
             ["example-node-a", "root@example-node-b", "10.0.0.9"]
  end

  test "hosts defaults to all machine file basenames" do
    source = Path.expand("..", __DIR__)

    assert NixSwarm.Deploy.hosts([], source) == [
             "root@example-node-a.local",
             "root@example-node-b.local"
           ]
  end

  test "rebuild command includes nixos-config when using non-flake rebuilds" do
    command = NixSwarm.Deploy.rebuild_command([], "/etc/nixos")

    assert command ==
             "'nixos-rebuild' 'switch' '-I' 'nixos-config=/etc/nixos/configuration.nix'"
  end

  test "rebuild command includes optional flake and build host" do
    command =
      NixSwarm.Deploy.rebuild_command(flake: ".#example-node-a", build_host: "builder@10.0.0.10")

    assert command ==
             "'nixos-rebuild' 'switch' '--flake' '.#example-node-a' '--build-host' 'builder@10.0.0.10'"
  end

  test "mutable source synchronization is disabled" do
    assert_raise ArgumentError, ~r/source synchronization was removed/, fn ->
      NixSwarm.Deploy.sync_command(
        "/tmp/nix-swarm",
        "root@example-node-a",
        "/etc/nixos/nix-swarm"
      )
    end
  end

  test "rebuild host command uses native remote deployment with strict host verification" do
    command =
      NixSwarm.Deploy.rebuild_host_command("example-node-a", "/etc/nixos", flake: ".")

    assert command =~ "NIX_SSHOPTS="
    assert command =~ "StrictHostKeyChecking=yes"
    refute command =~ "UserKnownHostsFile=/dev/null"
    refute command =~ "StrictHostKeyChecking=accept-new"
    assert command =~ "'nixos-rebuild'"
    assert command =~ "'--flake'"
    assert command =~ "'path:"
    assert command =~ "#example-node-a'"
    assert command =~ "'--target-host' 'example-node-a'"
    assert command =~ "'--use-remote-sudo'"
  end

  test "rebuild host command derives a configuration from an SSH host" do
    command =
      NixSwarm.Deploy.rebuild_host_command("root@example-control.local", "/etc/nixos", flake: ".")

    assert command =~ "#example-control'"
    assert command =~ "'--target-host' 'root@example-control.local'"
  end

  test "deploy commands reject unsafe remote inputs" do
    assert_raise ArgumentError, ~r/absolute path/, fn ->
      NixSwarm.Deploy.rebuild_host_command("root@example-node-a", "relative/path", flake: ".")
    end

    assert_raise ArgumentError, ~r/must not contain '\.\.'/, fn ->
      NixSwarm.Deploy.rebuild_host_command("root@example-node-a", "/etc/../tmp", [])
    end

    assert_raise ArgumentError, ~r/unsupported whitespace/, fn ->
      NixSwarm.Deploy.rebuild_host_command("root@example-node-a bad", "/etc/nixos", flake: ".")
    end
  end

  test "validation commands prebuild the NixOS system closure from the flake" do
    commands = NixSwarm.Deploy.validation_commands(["/tmp/nix-swarm/machines/example-node-a.nix"])

    assert commands == [
             "'nix' 'build' '--no-link' 'path:/tmp/nix-swarm#nixosConfigurations.example-node-a.config.system.build.toplevel'"
           ]
  end

  test "plan builds dry-run result commands per host" do
    source = Path.expand("..", __DIR__)

    plan =
      NixSwarm.Deploy.plan(
        hosts: "root@example-node-a.local,root@example-node-b.local",
        source: source,
        dry_run: true
      )

    assert plan.dry_run
    assert length(plan.validation.targets) == 2
    assert Enum.all?(plan.validation.commands, &String.contains?(&1, "nixosConfigurations"))

    assert Enum.map(plan.results, & &1.host) == [
             "root@example-node-a.local",
             "root@example-node-b.local"
           ]

    assert Enum.all?(plan.results, &String.contains?(&1.rebuild_command, "nixos-rebuild"))
    assert Enum.all?(plan.results, &String.contains?(&1.rebuild_command, "--target-host"))

    assert Enum.all?(
             plan.results,
             &String.contains?(&1.rebuild_command, "StrictHostKeyChecking=yes")
           )
  end

  test "plan targets all machine files by default" do
    source = Path.expand("..", __DIR__)
    plan = NixSwarm.Deploy.plan(source: source)

    assert Enum.map(plan.results, & &1.host) == [
             "root@example-node-a.local",
             "root@example-node-b.local"
           ]
  end

  test "plan accepts defaults maps for update flows" do
    source = Path.expand("..", __DIR__)
    plan = NixSwarm.Deploy.plan(NixSwarm.Deploy.defaults(source))

    assert plan.source == source

    assert Enum.map(plan.results, & &1.host) == [
             "root@example-node-a.local",
             "root@example-node-b.local"
           ]
  end

  test "deployment targets honor the evaluated code manifest" do
    source = Path.expand("..", __DIR__)

    assert NixSwarm.Deploy.deployment_targets(
             Path.join(source, "examples/config/cluster/cluster.nix")
           ) == [
             %{
               node: "nix-swarm@example-node-a.local",
               host: "root@example-node-a.local",
               configuration: "example-node-a",
               availability: "active"
             },
             %{
               node: "nix-swarm@example-node-b.local",
               host: "root@example-node-b.local",
               configuration: "example-node-b",
               availability: "active"
             }
           ]
  end

  test "the packaged starter plans its declared root SSH target" do
    source = Path.expand("../examples/starter", __DIR__)
    plan = NixSwarm.Deploy.plan(source: source, dry_run: true)

    assert plan.hosts == ["root@node-a"]
    assert plan.configurations == %{"root@node-a" => "node-a"}
  end

  test "plan orders canaries first and preserves bounded rollout batches" do
    source = Path.expand("..", __DIR__)

    plan =
      NixSwarm.Deploy.plan(
        source: source,
        hosts: ["root@example-node-b.local", "root@example-node-a.local"],
        canary_hosts: ["root@example-node-a.local"],
        max_unavailable: 1,
        configurations: %{
          "root@example-node-a.local" => "node-a",
          "root@example-node-b.local" => "node-b"
        }
      )

    assert plan.hosts == ["root@example-node-a.local", "root@example-node-b.local"]
    assert plan.canary_hosts == ["root@example-node-a.local"]

    assert Enum.map(plan.batches, &Enum.map(&1, fn result -> result.configuration end)) == [
             ["node-a"],
             ["node-b"]
           ]
  end

  test "manifest policy excludes maintenance hosts and configures readiness" do
    source = Path.expand("..", __DIR__)

    manifest = %{
      "schemaVersion" => 1,
      "nodes" => %{
        "nix-swarm@node-a" => %{
          "availability" => "active",
          "deployHost" => "root@node-a",
          "nixosConfiguration" => "node-a"
        },
        "nix-swarm@node-b" => %{
          "availability" => "maintenance",
          "deployHost" => "root@node-b",
          "nixosConfiguration" => "node-b"
        }
      },
      "deployment" => %{
        "healthTimeoutSec" => 45,
        "stableSamples" => 3,
        "autoRollback" => true
      }
    }

    plan = NixSwarm.Deploy.plan(source: source, deployment_manifest: manifest, dry_run: true)

    assert plan.hosts == ["root@node-a"]
    assert plan.health_timeout_sec == 45
    assert plan.health_stable_samples == 3
    assert plan.auto_rollback
  end

  test "deployment manifests fail closed on unsupported schemas" do
    assert_raise ArgumentError, ~r/schemaVersion/, fn ->
      NixSwarm.Deploy.deployment_manifest(".",
        deployment_manifest: %{"schemaVersion" => 2, "nodes" => %{"node@a" => %{}}}
      )
    end

    assert_raise ArgumentError, ~r/non-empty/, fn ->
      NixSwarm.Deploy.deployment_manifest(".",
        deployment_manifest: %{"schemaVersion" => 1, "nodes" => %{}}
      )
    end
  end

  test "deployment manifests reject unsafe node metadata" do
    source = Path.expand("..", __DIR__)

    invalid_availability = %{
      "schemaVersion" => 1,
      "nodes" => %{
        "nix-swarm@node-a" => %{
          "availability" => "offline",
          "deployHost" => "root@node-a",
          "nixosConfiguration" => "node-a"
        }
      }
    }

    assert_raise ArgumentError, ~r/invalid availability/, fn ->
      NixSwarm.Deploy.plan(
        source: source,
        deployment_manifest: invalid_availability,
        dry_run: true
      )
    end

    duplicate_host = %{
      "schemaVersion" => 1,
      "nodes" => %{
        "nix-swarm@node-a" => %{
          "deployHost" => "root@same",
          "nixosConfiguration" => "node-a"
        },
        "nix-swarm@node-b" => %{
          "deployHost" => "root@same",
          "nixosConfiguration" => "node-b"
        }
      }
    }

    assert_raise ArgumentError, ~r/duplicate deploy hosts/, fn ->
      NixSwarm.Deploy.plan(source: source, deployment_manifest: duplicate_host, dry_run: true)
    end
  end

  test "maintenance peers may remain connected during a healthy rollout" do
    node = :"nix-swarm@node-a"
    maintenance = :"nix-swarm@node-b"

    overview = %{
      members: %{
        live_nodes: [node, maintenance],
        configured_nodes: [node, maintenance],
        required_nodes: [node]
      },
      status: %{
        queried_node: node,
        config_consistent?: true,
        placement_diagnostics: [],
        placements: %{},
        nodes: [{node, %{services: []}}, {maintenance, %{services: []}}]
      }
    }

    assert NixSwarm.Deploy.healthy_overview?(overview)
  end

  test "rollback uses the previous native NixOS generation" do
    source = Path.expand("..", __DIR__)

    plan =
      NixSwarm.Deploy.rollback(
        source: source,
        hosts: ["root@example-node-a.local"],
        dry_run: true
      )

    assert plan.dry_run
    assert plan.validation.commands == []
    assert [target] = plan.results
    assert target.rebuild_command =~ "'nixos-rebuild' 'switch' '--rollback'"
    assert target.rebuild_command =~ "'--target-host' 'root@example-node-a.local'"
    assert target.rebuild_command =~ "'--use-remote-sudo'"
  end

  test "rolling health gates allow expected config skew only before the final batch" do
    node_a = :"nix-swarm@node-a"
    node_b = :"nix-swarm@node-b"

    overview = %{
      members: %{live_nodes: [node_a, node_b], configured_nodes: [node_a, node_b]},
      status: %{
        queried_node: node_a,
        config_consistent?: false,
        placement_diagnostics: [
          %{severity: :error, reason: :config_digest_mismatch}
        ],
        placements: %{
          "web" => [
            %{owner: node_a, unit: "web@0.service"},
            %{owner: node_b, unit: "web@1.service"}
          ]
        },
        nodes: [
          {node_a,
           %{
             services: [
               %{
                 name: "web",
                 units: [
                   %{owner: node_a, unit: "web@0.service", status: :running},
                   %{owner: node_b, unit: "web@1.service", status: :inactive}
                 ]
               }
             ]
           }},
          {node_b,
           %{
             services: [
               %{
                 name: "web",
                 units: [
                   %{owner: node_a, unit: "web@0.service", status: :inactive},
                   %{owner: node_b, unit: "web@1.service", status: :running}
                 ]
               }
             ]
           }}
        ]
      }
    }

    assert NixSwarm.Deploy.healthy_overview?(overview, false)
    refute NixSwarm.Deploy.healthy_overview?(overview, true)

    converged =
      overview
      |> put_in([:status, :config_consistent?], true)
      |> put_in([:status, :placement_diagnostics], [])

    assert NixSwarm.Deploy.healthy_overview?(converged, true)
  end

  test "rolling health gates reject unreachable nodes and unhealthy local units" do
    node = :"nix-swarm@node-a"

    base = %{
      members: %{live_nodes: [node], configured_nodes: [node]},
      status: %{
        queried_node: node,
        config_consistent?: true,
        placement_diagnostics: [],
        placements: %{},
        nodes: [
          {node,
           %{
             services: [
               %{name: "web", units: [%{owner: node, status: :failed, unit: "web.service"}]}
             ]
           }}
        ]
      }
    }

    refute NixSwarm.Deploy.healthy_overview?(base, false)

    unreachable = put_in(base, [:status, :nodes], [{node, %{error: :node_unreachable}}])
    refute NixSwarm.Deploy.healthy_overview?(unreachable, false)
    refute NixSwarm.Deploy.healthy_overview?(%{}, false)
  end

  test "final health gate rejects stale or failed reconciliation state" do
    node = :"nix-swarm@node-a"
    digest = "config-digest"

    base = %{
      members: %{live_nodes: [node], configured_nodes: [node]},
      status: %{
        queried_node: node,
        config_consistent?: true,
        placement_diagnostics: [],
        placements: %{},
        nodes: [
          {node,
           %{
             config_digest: digest,
             services: [],
             operational_state: %{
               config_digest: digest,
               reconciled_at: 1_000,
               failed_results: 0
             }
           }}
        ]
      }
    }

    assert NixSwarm.Deploy.healthy_overview?(base, true)

    failed =
      put_in(
        base,
        [:status, :nodes, Access.at(0), Access.elem(1), :operational_state, :failed_results],
        1
      )

    refute NixSwarm.Deploy.healthy_overview?(failed, true)

    stale =
      put_in(
        base,
        [:status, :nodes, Access.at(0), Access.elem(1), :operational_state, :config_digest],
        "old-digest"
      )

    refute NixSwarm.Deploy.healthy_overview?(stale, true)
  end
end
