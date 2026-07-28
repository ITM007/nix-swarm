defmodule NixSwarmDeployStateMachineTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Deploy.StateMachine

  test "bootstrap and upgrade are closure-first, credential-safe, and readiness ordered" do
    state = StateMachine.new(["root@bootstrap", "root@peer-a", "root@peer-b"], max_unavailable: 1)

    assert {:error, :closure_required, unchanged} =
             StateMachine.dispatch(state, {:activate_bootstrap, "root@bootstrap"})

    assert unchanged == state

    state = dispatch!(state, {:classify, "root@bootstrap", :new_nixos_host})
    state = dispatch!(state, {:build_closure, "root@bootstrap"})
    state = dispatch!(state, {:enroll_credential, "root@bootstrap"})
    state = dispatch!(state, {:activate_bootstrap, "root@bootstrap"})

    assert {:error, :bootstrap_not_ready, _} =
             StateMachine.dispatch(state, {:roll_existing, ["root@peer-a"]})

    state = dispatch!(state, {:bootstrap_ready, "root@bootstrap"})
    state = dispatch!(state, {:classify, "root@peer-a", :existing_outdated})
    state = dispatch!(state, {:build_closure, "root@peer-a"})
    state = dispatch!(state, {:roll_existing, ["root@peer-a"]})

    assert state.phase == :existing_rolled
    assert StateMachine.mutation_hosts(state) == ["root@bootstrap", "root@peer-a"]
  end

  test "mismatched credentials fail closed before enrollment or activation" do
    state = StateMachine.new(["root@node-a"])
    state = dispatch!(state, {:classify, "root@node-a", :new_nixos_host, credential: :mismatched})
    state = dispatch!(state, {:build_closure, "root@node-a"})

    assert {:error, :credential_mismatch, state} =
             StateMachine.dispatch(state, {:enroll_credential, "root@node-a"})

    assert {:error, :credential_mismatch, ^state} =
             StateMachine.dispatch(state, {:activate_bootstrap, "root@node-a"})

    assert StateMachine.mutation_hosts(state) == []
  end

  test "rollout stages stay within max unavailable and preserve the planned target set" do
    targets =
      for {classification, host} <-
            Enum.with_index(
              [:new_nixos_host, :existing_outdated, :existing_outdated, :existing_in_sync],
              1
            ) do
        %{
          host: "root@node-#{host}",
          configuration: "node-#{host}",
          classification: classification
        }
      end

    for max_unavailable <- 1..3 do
      state = StateMachine.new(Enum.map(targets, & &1.host), max_unavailable: max_unavailable)
      assert {:ok, planned} = StateMachine.plan(state, targets)
      assert Enum.all?(planned.stages, &(length(&1) <= max_unavailable))

      assert Enum.map(List.flatten(planned.stages), & &1.host) |> Enum.sort() ==
               Enum.map(targets, & &1.host) |> Enum.sort()
    end
  end

  test "rollback touches attempted activated hosts only and leaves unattempted hosts unchanged" do
    state = StateMachine.new(["root@a", "root@b", "root@c"], max_unavailable: 1)

    state =
      state
      |> dispatch!({:classify, "root@a", :new_nixos_host})
      |> dispatch!({:build_closure, "root@a"})
      |> dispatch!({:enroll_credential, "root@a"})
      |> dispatch!({:activate_bootstrap, "root@a"})
      |> dispatch!({:bootstrap_ready, "root@a"})
      |> dispatch!({:classify, "root@b", :existing_outdated})
      |> dispatch!({:build_closure, "root@b"})
      |> dispatch!({:roll_existing, ["root@b"]})

    before_unattempted = StateMachine.host_snapshot(state, "root@c")
    state = dispatch!(state, :rollback)

    assert state.rollback_hosts == ["root@a", "root@b"]
    assert StateMachine.host_snapshot(state, "root@c") == before_unattempted
    refute "root@c" in StateMachine.mutation_hosts(state)
  end

  test "final convergence requires every independent readiness signal" do
    state = StateMachine.new(["root@a"])
    state = dispatch!(state, {:classify, "root@a", :existing_outdated})
    state = dispatch!(state, {:build_closure, "root@a"})
    state = %{state | bootstrap_ready: true, phase: :bootstrap_ready}
    state = dispatch!(state, {:roll_existing, ["root@a"]})

    for missing <- [:membership, :digest, :placements, :readiness, :reconciliation] do
      checks =
        StateMachine.final_checks(state)
        |> Map.keys()
        |> Map.new(&{&1, true})
        |> Map.put(missing, false)

      assert {:error, {:not_converged, ^missing}, _} =
               StateMachine.dispatch(%{state | final_checks: checks}, :converge)
    end

    assert {:ok, converged} = StateMachine.dispatch(state, {:set_final_checks, :all})
    assert {:ok, converged} = StateMachine.dispatch(converged, :converge)
    assert converged.phase == :converged
  end

  test "operator death is isolated and active removal requires draining then maintenance" do
    state = StateMachine.new(["root@a"])
    original_agent = StateMachine.agent_snapshot(state, "root@a")

    state = dispatch!(state, :kill_operator)
    assert StateMachine.agent_snapshot(state, "root@a") == original_agent

    assert {:error, :operator_dead, ^state} =
             StateMachine.dispatch(state, {:classify, "root@a", :existing_outdated})

    state = dispatch!(%{state | operator_alive: true}, {:classify, "root@a", :existing_outdated})
    assert {:error, :must_drain_first, _} = StateMachine.dispatch(state, {:remove, "root@a"})
    state = dispatch!(state, {:draining, "root@a"})
    assert {:error, :must_maintain_first, _} = StateMachine.dispatch(state, {:remove, "root@a"})
    state = dispatch!(state, {:maintenance, "root@a"})
    state = dispatch!(state, {:remove, "root@a"})

    assert StateMachine.hosts(state) == []
  end

  test "seeded command sequences are deterministic and preserve model invariants" do
    commands = StateMachine.seeded_commands(73, ["root@a", "root@b", "root@c"])

    assert commands == StateMachine.seeded_commands(73, ["root@a", "root@b", "root@c"])

    {_state, violations} =
      Enum.reduce(commands, {StateMachine.new(["root@a", "root@b", "root@c"]), []}, fn command,
                                                                                       {state,
                                                                                        violations} ->
        {result, next_state} = StateMachine.apply(state, command)
        {next_state, violations ++ StateMachine.invariant_violations(next_state, result)}
      end)

    assert violations == []
  end

  defp dispatch!(state, command) do
    case StateMachine.dispatch(state, command) do
      {:ok, state} -> state
      {:error, reason, _state} -> flunk("#{inspect(command)} failed: #{inspect(reason)}")
    end
  end
end
