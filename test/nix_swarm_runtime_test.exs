defmodule NixSwarmRuntimeTest do
  use ExUnit.Case, async: false

  test "runtime role is explicit and validated" do
    previous = System.get_env("NIX_SWARM_ROLE")

    on_exit(fn ->
      if previous,
        do: System.put_env("NIX_SWARM_ROLE", previous),
        else: System.delete_env("NIX_SWARM_ROLE")
    end)

    System.put_env("NIX_SWARM_ROLE", "operator")
    assert NixSwarm.Application.role() == :operator

    System.put_env("NIX_SWARM_ROLE", "agent")
    assert NixSwarm.Application.role() == :agent

    System.put_env("NIX_SWARM_ROLE", "invalid")
    assert_raise ArgumentError, ~r/invalid Nix-Swarm runtime role/, &NixSwarm.Application.role/0
  end

  test "runtime tuning knobs from the Nix bridge are honored and bounded" do
    config =
      NixSwarm.Config.normalize(%{
        services: [%{name: "api", replicas: 2, unit_template: "api@%{slot}.service"}],
        runtime: %{
          reconcile_interval_ms: 1_234,
          command_timeout_ms: 60_000
        }
      })

    assert config.runtime.reconcile_interval_ms == 1_234
    assert config.runtime.command_timeout_ms == 60_000
    assert config.runtime.connect_interval_ms == 1_000
    assert config.runtime.failure_grace_ms == 5_000
    assert config.runtime.recovery_stabilization_ms == 2_000
    assert :ok == NixSwarm.Config.validate(config)

    default = NixSwarm.Config.normalize(%{services: []})
    assert default.runtime.connect_interval_ms == 1_000
    assert default.runtime.reconcile_interval_ms == 1_000
    assert default.runtime.autoscale_interval_ms == 1_000
    assert default.runtime.failure_grace_ms == 5_000
    assert default.runtime.recovery_stabilization_ms == 2_000
    assert default.runtime.command_timeout_ms == 5_000
  end

  test "zero or runaway runtime values are rejected by validation" do
    for {key, value} <- [
          reconcile_interval_ms: 0,
          connect_interval_ms: -1,
          autoscale_interval_ms: 0,
          failure_grace_ms: 50,
          command_timeout_ms: 1,
          recovery_stabilization_ms: 3_700_000
        ] do
      config = NixSwarm.Config.normalize(%{services: [], runtime: %{key => value}})

      assert {:error, message} = NixSwarm.Config.validate(config)
      assert message =~ Atom.to_string(key), "missing bound error for #{key}: #{message}"
    end
  end

  test "removed service tuning knobs still do not leak into the public surface" do
    config =
      NixSwarm.Config.normalize(%{
        services: [%{name: "api", replicas: 2, unit_template: "api@%{slot}.service"}]
      })

    service = hd(config.services)
    refute Map.has_key?(service, :readiness)
    refute Map.has_key?(service.autoscaling, :sample_window_sec)
    refute Map.has_key?(service.autoscaling, :scale_up_cooldown_sec)
    refute Map.has_key?(service.autoscaling, :scale_down_cooldown_sec)
    refute Map.has_key?(service.autoscaling, :max_step)
  end

  test "normalized public configuration contains only the opinionated service surface" do
    config =
      NixSwarm.Config.normalize(%{
        services: [%{name: "api", replicas: 1, allowedNodes: []}],
        nodes: %{}
      })

    service = hd(config.services)

    assert Map.keys(service) |> Enum.sort() ==
             [:allowed_nodes, :autoscaling, :name, :replicas, :unit_template]

    for removed_key <- [
          :ingress,
          :healthcheck,
          :settings,
          :preferred_nodes,
          :constraints,
          :max_replicas_per_node,
          :readiness
        ] do
      refute Map.has_key?(service, removed_key), "removed service field leaked: #{removed_key}"
    end

    refute Map.has_key?(config, :ingress)
  end

  test "agent supervision owns immutable config and durable operational state" do
    System.put_env("NIX_SWARM_ROLE", "agent")
    {:ok, _apps} = Application.ensure_all_started(:nix_swarm)
    children = Supervisor.which_children(NixSwarm.Supervisor)

    assert Enum.any?(children, fn {id, _pid, _type, _modules} -> id == NixSwarm.Config.Server end)

    assert Enum.any?(children, fn {id, _pid, _type, _modules} ->
             id == NixSwarm.OperationalState
           end)

    assert NixSwarm.Config.Server.metadata().digest == NixSwarm.Config.digest()
  end
end
