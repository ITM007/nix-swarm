defmodule NixSwarmAutoscalerTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Autoscaler

  @policy %{
    min_replicas: 2,
    max_replicas: 8,
    cpu_target_percent: 65,
    max_step: 1
  }

  test "CPU recommendations are bounded by step and declared capacity" do
    assert Autoscaler.recommend_target(2, 95.0, @policy) == 3
    assert Autoscaler.recommend_target(8, 95.0, @policy) == 8
    assert Autoscaler.recommend_target(5, 10.0, @policy) == 4
    assert Autoscaler.recommend_target(2, 10.0, @policy) == 2
    assert Autoscaler.recommend_target(4, 60.0, @policy) == 4
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
              maxStep: 2
            }
          }
        ]
      })

    service = hd(config.services)
    assert service.autoscaling.enabled
    assert service.autoscaling.min_replicas == 1
    assert service.autoscaling.max_replicas == 6
    assert service.autoscaling.cpu_target_percent == 70
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
              maxStep: 0
            }
          }
        ]
      })

    assert {:error, message} = NixSwarm.Config.validate(config)
    assert message =~ "min_replicas"
    assert message =~ "max_replicas"
    assert message =~ "cpu_target_percent"
    assert message =~ "max_step"
  end
end
