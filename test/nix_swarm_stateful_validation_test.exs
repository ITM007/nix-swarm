defmodule NixSwarmStatefulValidationTest do
  use ExUnit.Case, async: true

  defp config_with(service_overrides) do
    service =
      %{
        name: "db",
        replicas: 1,
        state: %{dirs: ["/var/lib/db"], backup: %{target: "ssh://borg@backup/./db"}}
      }
      |> Map.merge(service_overrides)

    NixSwarm.Config.normalize(%{services: [service], nodes: %{}})
  end

  test "a single-replica stateful service validates" do
    assert :ok == NixSwarm.Config.validate(config_with(%{}))
  end

  test "stateful service with replicas above one is rejected" do
    config = config_with(%{replicas: 3})

    assert {:error, message} = NixSwarm.Config.validate(config)
    assert message =~ "db is stateful and must run single-writer"
  end

  test "stateful service with replicas zero is rejected" do
    config = config_with(%{replicas: 0})

    assert {:error, message} = NixSwarm.Config.validate(config)
    assert message =~ "db is stateful and must run single-writer"
  end

  test "stateful service with autoscaling above one replica is rejected" do
    config =
      config_with(%{
        autoscaling: %{enabled: true, min_replicas: 1, max_replicas: 3}
      })

    assert {:error, message} = NixSwarm.Config.validate(config)
    assert message =~ "db is stateful and must not autoscale beyond one replica"
  end

  test "stateful service with autoscaling capped at one is accepted" do
    config =
      config_with(%{
        autoscaling: %{enabled: true, min_replicas: 1, max_replicas: 1}
      })

    assert :ok == NixSwarm.Config.validate(config)
  end

  test "stateless services may still replicate freely" do
    config =
      NixSwarm.Config.normalize(%{
        services: [%{name: "web", replicas: 3, unit_template: "web@%{slot}.service"}],
        nodes: %{}
      })

    assert :ok == NixSwarm.Config.validate(config)
  end

  test "stateless services may keep autoscaling" do
    config =
      NixSwarm.Config.normalize(%{
        services: [
          %{name: "web", replicas: 1, autoscaling: %{enabled: true, max_replicas: 5}}
        ],
        nodes: %{}
      })

    assert :ok == NixSwarm.Config.validate(config)
  end
end
