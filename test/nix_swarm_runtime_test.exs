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

  test "configuration validation rejects unsafe service and runtime contracts" do
    config =
      NixSwarm.Config.normalize(%{
        services: [
          %{name: "api", replicas: 2, unit_template: "api.service"},
          %{name: "api", replicas: 1, unit_template: "../api.service"}
        ],
        runtime: %{reconcile_interval_ms: 0}
      })

    assert {:error, message} = NixSwarm.Config.validate(config)
    assert message =~ "duplicate service name"
    assert message =~ "must contain %{slot}"
    assert message =~ "unsafe systemd unit"
    assert message =~ "reconcile_interval_ms must be between 100 and 3600000"
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
