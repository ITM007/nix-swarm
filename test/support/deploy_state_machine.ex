defmodule NixSwarm.Deploy.StateMachine do
  import Kernel, except: [apply: 2]

  @moduledoc "A deterministic, test-only deployment safety model."

  alias NixSwarm.Deploy.Rollout

  @checks [:membership, :digest, :placements, :readiness, :reconciliation]

  def new(hosts, opts \\ []) do
    max_unavailable = Keyword.get(opts, :max_unavailable, 1)

    targets =
      Map.new(hosts, fn host ->
        host = to_string(host)

        {host,
         %{
           classification: :prepared,
           credential: :unknown,
           closure: false,
           enrolled: false,
           activated: false,
           desired: :unchanged,
           observed: :unchanged,
           blockers: []
         }}
      end)

    %{
      phase: :prepared,
      targets: targets,
      max_unavailable: max_unavailable,
      bootstrap_ready: false,
      mutations: [],
      rollback_hosts: [],
      operator_alive: true,
      final_checks: Map.new(@checks, &{&1, false})
    }
  end

  def hosts(state), do: Map.keys(state.targets) |> Enum.sort()
  def mutation_hosts(state), do: state.mutations
  def final_checks(state), do: state.final_checks
  def host_snapshot(state, host), do: Map.get(state.targets, host)
  def agent_snapshot(state, host), do: host_snapshot(state, host)

  def plan(state, targets) do
    {:ok, Rollout.plan(targets, max_unavailable: state.max_unavailable)}
  rescue
    error in ArgumentError -> {:error, error.message}
  end

  def dispatch(state, command) do
    case apply(state, command) do
      {:ok, next_state} -> {:ok, next_state}
      {{:error, reason}, next_state} -> {:error, reason, next_state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def apply(%{operator_alive: false} = state, :kill_operator), do: {:ok, state}

  def apply(%{operator_alive: false} = state, _command),
    do: {{:error, :operator_dead}, state}

  def apply(state, :kill_operator), do: {:ok, %{state | operator_alive: false}}

  def apply(state, {:classify, host, classification}),
    do: apply(state, {:classify, host, classification, []})

  def apply(state, {:classify, host, classification, opts}) do
    host = to_string(host)

    with {:ok, target} <- fetch_target(state, host),
         {:ok, classified} <- classify_target(target, classification, opts) do
      state = put_in(state, [:targets, host], classified)
      {:ok, %{state | phase: :preflighted}}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  def apply(state, {:build_closure, host}) do
    with {:ok, target} <- fetch_target(state, host),
         :ok <- require_classified(target) do
      {:ok,
       state |> put_in([:targets, to_string(host), :closure], true) |> advance(:closures_built)}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  def apply(state, {:enroll_credential, host}) do
    host = to_string(host)

    with {:ok, target} <- fetch_target(state, host),
         :ok <- require_closure(target),
         :ok <- reject_mismatch(target),
         true <- target.classification in [:new_nixos_host, :installed_inactive] do
      {:ok, state |> put_in([:targets, host, :enrolled], true) |> advance(:credentials_enrolled)}
    else
      false -> {{:error, :enrollment_not_required}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  def apply(state, {:activate_bootstrap, host}) do
    host = to_string(host)

    with {:ok, target} <- fetch_target(state, host),
         :ok <- require_closure(target),
         :ok <- reject_mismatch(target),
         true <- target.classification in [:new_nixos_host, :installed_inactive],
         true <- target.enrolled do
      state = put_in(state, [:targets, host, :activated], true)
      state = put_in(state, [:targets, host, :desired], :active)
      state = put_in(state, [:targets, host, :observed], :active)
      {:ok, %{state | mutations: state.mutations ++ [host], phase: :bootstrap_activated}}
    else
      false -> {{:error, :credential_enrollment_required}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  def apply(state, {:bootstrap_ready, host}) do
    with {:ok, target} <- fetch_target(state, host),
         true <- target.activated do
      {:ok, %{state | phase: :bootstrap_ready, bootstrap_ready: true}}
    else
      false -> {{:error, :bootstrap_activation_required}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  def apply(state, {:roll_existing, hosts}) when is_list(hosts) do
    hosts = Enum.map(hosts, &to_string/1)

    with :ok <- require_bootstrap_ready(state),
         true <- hosts != [],
         true <- length(hosts) <= state.max_unavailable,
         :ok <- Enum.reduce_while(hosts, :ok, &rollable(state, &1, &2)) do
      targets =
        Enum.reduce(hosts, state.targets, fn host, targets ->
          targets
          |> put_in([host, :activated], true)
          |> put_in([host, :desired], :active)
          |> put_in([host, :observed], :active)
        end)

      {:ok,
       %{state | targets: targets, mutations: state.mutations ++ hosts, phase: :existing_rolled}}
    else
      false -> {{:error, :batch_exceeds_max_unavailable}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  def apply(state, :rollback) do
    targets =
      Enum.reduce(state.mutations, state.targets, fn host, targets ->
        targets
        |> put_in([host, :desired], :rolled_back)
        |> put_in([host, :observed], :rolled_back)
      end)

    {:ok, %{state | targets: targets, rollback_hosts: state.mutations}}
  end

  def apply(state, {:set_final_checks, :all}),
    do: {:ok, %{state | final_checks: Map.new(@checks, &{&1, true})}}

  def apply(state, :converge) do
    case Enum.find(@checks, &(state.final_checks[&1] != true)) do
      nil -> {:ok, %{state | phase: :converged}}
      missing -> {{:error, {:not_converged, missing}}, state}
    end
  end

  def apply(state, {:draining, host}), do: transition_status(state, host, :draining)

  def apply(state, {:maintenance, host}) do
    with {:ok, _target} <- fetch_target(state, host) do
      host = to_string(host)
      {:ok, put_in(state, [:targets, host, :observed], :maintenance)}
    end
  end

  def apply(state, {:remove, host}) do
    host = to_string(host)

    with {:ok, target} <- fetch_target(state, host),
         true <- target.desired == :draining,
         true <- target.observed == :maintenance do
      {:ok, %{state | targets: Map.delete(state.targets, host)}}
    else
      false ->
        {{:error,
          if(get_in(state, [:targets, host, :desired]) != :draining,
            do: :must_drain_first,
            else: :must_maintain_first
          )}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  def apply(state, _command), do: {:ok, state}

  def invariant_violations(state, _result) do
    violations = []

    violations =
      if state.phase == :existing_rolled and
           Enum.any?(state.targets, fn {_h, t} ->
             t.activated and t.classification in [:existing_outdated, :existing_in_sync] and
               not t.closure
           end), do: violations ++ [:closure_before_mutation], else: violations

    violations =
      if state.mutations != [] and not state.bootstrap_ready and state.phase == :existing_rolled,
        do: violations ++ [:readiness_order],
        else: violations

    violations
  end

  def seeded_commands(seed, hosts) do
    :rand.seed(:exsplus, {seed + 1, seed + 2, seed + 3})

    choices = [
      :kill_operator,
      {:classify, hd(hosts), :new_nixos_host},
      {:build_closure, hd(hosts)},
      {:enroll_credential, hd(hosts)},
      {:activate_bootstrap, hd(hosts)},
      {:bootstrap_ready, hd(hosts)},
      {:rollback},
      :converge
    ]

    for _ <- 1..24, do: Enum.at(choices, :rand.uniform(length(choices)) - 1)
  end

  defp classify_target(target, classification, opts) do
    credential =
      Keyword.get(
        opts,
        :credential,
        if(classification == :new_nixos_host, do: :missing, else: :present)
      )

    {:ok,
     %{
       target
       | classification: if(credential == :mismatched, do: :incompatible, else: classification),
         credential: credential,
         desired: :unchanged,
         observed: :unchanged,
         blockers: []
     }}
  end

  defp transition_status(state, host, status) do
    with {:ok, _target} <- fetch_target(state, host) do
      host = to_string(host)

      {:ok,
       state
       |> put_in([:targets, host, :desired], status)
       |> put_in([:targets, host, :observed], status)}
    end
  end

  defp rollable(state, host, :ok) do
    case fetch_target(state, host) do
      {:ok, target} ->
        cond do
          target.classification not in [:existing_outdated, :existing_in_sync] ->
            {:halt, {:error, :not_existing}}

          not target.closure ->
            {:halt, {:error, :closure_required}}

          true ->
            {:cont, :ok}
        end

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp fetch_target(state, host),
    do:
      if(Map.has_key?(state.targets, to_string(host)),
        do: {:ok, state.targets[to_string(host)]},
        else: {:error, :unknown_host}
      )

  defp require_classified(%{classification: :prepared}), do: {:error, :classification_required}
  defp require_classified(_), do: :ok
  defp require_closure(%{closure: true}), do: :ok
  defp require_closure(_), do: {:error, :closure_required}
  defp reject_mismatch(%{credential: :mismatched}), do: {:error, :credential_mismatch}
  defp reject_mismatch(_), do: :ok
  defp require_bootstrap_ready(%{bootstrap_ready: true}), do: :ok
  defp require_bootstrap_ready(_), do: {:error, :bootstrap_not_ready}
  defp advance(state, phase), do: %{state | phase: phase}
end
