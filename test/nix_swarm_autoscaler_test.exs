defmodule NixSwarmAutoscalerTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Autoscaler

  @policy %{
    min_replicas: 2,
    max_replicas: 8,
    cpu_target_percent: 65,
    memory_target_percent: 80
  }

  test "CPU recommendations are bounded by step and declared capacity" do
    assert Autoscaler.recommend_target(2, %{cpu_percent: 95.0, memory_percent: 20.0}, @policy) ==
             3

    assert Autoscaler.recommend_target(8, %{cpu_percent: 95.0, memory_percent: 20.0}, @policy) ==
             8

    assert Autoscaler.recommend_target(5, %{cpu_percent: 10.0, memory_percent: 20.0}, @policy) ==
             4

    assert Autoscaler.recommend_target(2, %{cpu_percent: 10.0, memory_percent: 20.0}, @policy) ==
             2

    assert Autoscaler.recommend_target(4, %{cpu_percent: 60.0, memory_percent: 80.0}, @policy) ==
             4
  end

  test "memory can independently trigger scale up and both metrics are required to scale down" do
    assert Autoscaler.recommend_target(2, %{cpu_percent: 20.0, memory_percent: 90.0}, @policy) ==
             3

    assert Autoscaler.recommend_target(4, %{cpu_percent: 20.0, memory_percent: 60.0}, @policy) ==
             4

    assert Autoscaler.recommend_target(4, %{cpu_percent: 40.0, memory_percent: 50.0}, @policy) ==
             3

    assert Autoscaler.recommend_target(4, %{cpu_percent: 40.0, memory_percent: nil}, @policy) == 3
  end

  test "memory max is unavailable when systemd reports an unlimited value" do
    assert NixSwarm.Executor.Systemd.memory_percent(%{
             "MemoryCurrent" => 10,
             "MemoryMax" => "infinity"
           }) == nil

    assert NixSwarm.Executor.Systemd.memory_percent(%{"MemoryCurrent" => 50, "MemoryMax" => 100}) ==
             50.0
  end

  test "autoscaling policy is normalized and validated from code" do
    config =
      NixSwarm.Config.normalize(%{
        services: [
          %{
            name: "api",
            replicas: 2,
            autoscaling: %{
              enable: true,
              minReplicas: 1,
              maxReplicas: 6,
              cpuTargetPercent: 70,
              memoryTargetPercent: 80
            }
          }
        ]
      })

    service = hd(config.services)
    assert service.autoscaling.enabled
    assert service.autoscaling.min_replicas == 1
    assert service.autoscaling.max_replicas == 6
    assert service.autoscaling.cpu_target_percent == 70
    assert service.autoscaling.memory_target_percent == 80
    assert NixSwarm.Service.capacity_replicas(service) == 6
    assert :ok = NixSwarm.Config.validate(config)
  end

  test "invalid autoscaling bounds fail configuration validation" do
    config =
      NixSwarm.Config.normalize(%{
        services: [
          %{
            name: "api",
            replicas: 2,
            autoscaling: %{
              enable: true,
              minReplicas: 3,
              maxReplicas: 1,
              cpuTargetPercent: 0,
              memoryTargetPercent: 0
            }
          }
        ]
      })

    assert {:error, message} = NixSwarm.Config.validate(config)
    assert message =~ "min_replicas"
    assert message =~ "max_replicas"
    assert message =~ "cpu_target_percent"
    assert message =~ "memory_target_percent"
  end

  test "aggregates CPU samples by unit count and ignores missing samples" do
    snapshots = [
      %{samples: %{"api" => %{cpu_percent: 90.0, unit_count: 1}}},
      %{samples: %{"api" => %{cpu_percent: 30.0, unit_count: 3}}},
      %{samples: %{"api" => %{cpu_percent: nil, unit_count: 1}}},
      %{samples: %{"other" => %{cpu_percent: 100.0, unit_count: 1}}}
    ]

    assert Autoscaler.aggregate_sample(snapshots, "api") == %{
             cpu_percent: 45.0,
             memory_percent: nil
           }

    assert Autoscaler.aggregate_sample(snapshots, "missing") == nil
  end

  test "restored targets are clamped to enabled service capacity" do
    config =
      NixSwarm.Config.normalize(%{
        services: [
          %{
            name: "api",
            replicas: 2,
            unit_template: "api@%{slot}.service",
            autoscaling: %{enable: true, minReplicas: 1, maxReplicas: 4}
          },
          %{name: "fixed", replicas: 1}
        ]
      })

    assert Autoscaler.normalize_targets(config, %{"api" => 99, "fixed" => 99}) == %{"api" => 4}
    assert Autoscaler.normalize_targets(config, %{"api" => 0}) == %{"api" => 1}
  end

  test "invalidated decisions cannot retain targets for removed services" do
    config =
      NixSwarm.Config.normalize(%{
        services: [
          %{
            name: "api",
            replicas: 2,
            autoscaling: %{enable: true, minReplicas: 1, maxReplicas: 4}
          }
        ]
      })

    assert Autoscaler.targets_after_decisions(config, %{}) == %{"api" => 2}

    assert Autoscaler.targets_after_decisions(config, %{
             "removed" => %{target: 4}
           }) == %{"api" => 2}
  end

  test "decision validation rejects stale, foreign, and out-of-range decisions" do
    node = :"nix-swarm@autoscaler-test"

    config =
      NixSwarm.Config.normalize(%{
        peers: [node],
        nodes: %{node => %{labels: ["apps"]}},
        services: [
          %{
            name: "api",
            replicas: 2,
            unit_template: "api@%{slot}.service",
            autoscaling: %{enable: true, minReplicas: 1, maxReplicas: 4}
          }
        ]
      })

    service = hd(config.services)
    digest = NixSwarm.Config.digest_for(config)
    fingerprint = Autoscaler.membership_fingerprint([node])

    decision = %{
      service: "api",
      target: 3,
      owner: node,
      config_digest: digest,
      membership_fingerprint: fingerprint,
      expires_at_ms: 2_000,
      issued_at_ms: 1_000
    }

    assert Autoscaler.valid_decision?(decision, service, digest, [node], config, 1_500)

    refute Autoscaler.valid_decision?(
             %{decision | expires_at_ms: 1_499},
             service,
             digest,
             [node],
             config,
             1_500
           )

    refute Autoscaler.valid_decision?(
             %{decision | owner: :"nix-swarm@other"},
             service,
             digest,
             [node],
             config,
             1_500
           )

    refute Autoscaler.valid_decision?(
             %{decision | target: 5},
             service,
             digest,
             [node],
             config,
             1_500
           )

    refute Autoscaler.valid_decision?(
             %{decision | config_digest: "stale"},
             service,
             digest,
             [node],
             config,
             1_500
           )
  end

  test "membership fingerprints are order independent but change on membership changes" do
    first = Autoscaler.membership_fingerprint([:"node-b@test", :"node-a@test"])
    same = Autoscaler.membership_fingerprint([:"node-a@test", :"node-b@test"])
    changed = Autoscaler.membership_fingerprint([:"node-a@test", :"node-c@test"])

    assert first == same
    refute first == changed
  end
end
