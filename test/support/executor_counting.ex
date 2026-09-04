defmodule NixSwarm.Executor.Counting do
  @moduledoc false

  # Test-only executor adapter that counts every operation before delegating
  # to the file-backed fake adapter. Counters live in a per-VM Agent named
  # from the executor root, so a multi-node :peer cluster keeps one counter
  # per node and the controller reads snapshots over RPC.

  alias NixSwarm.Executor.Fake

  @ops [
    :start_unit,
    :stop_unit,
    :restart_unit,
    :unit_status,
    :batch_unit_status,
    :unit_metrics,
    :unit_cpu_usage,
    :unit_memory_usage
  ]

  for op <- @ops do
    def unquote(op)(unit, config) do
      bump(config, unquote(op))
      Fake.unquote(op)(unit, config)
    end
  end

  def unit_logs(unit, lines, config) do
    bump(config, :unit_logs)
    Fake.unit_logs(unit, lines, config)
  end

  @doc "Resets the counter for the given executor root, returning the old snapshot."
  def reset(config) do
    old = snapshot(config)
    ensure_agent(config)
    Agent.update(agent_name(config), fn _ -> %{} end)
    old
  end

  @doc "Returns the operation counts observed so far for the executor root."
  def snapshot(config) do
    ensure_agent(config)
    Agent.get(agent_name(config), & &1)
  end

  defp bump(config, op) do
    ensure_agent(config)
    Agent.update(agent_name(config), fn counts -> Map.update(counts, op, 1, &(&1 + 1)) end)
  end

  defp ensure_agent(config) do
    name = agent_name(config)

    if Process.whereis(name) do
      :ok
    else
      case Agent.start_link(fn -> %{} end, name: name) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> raise "could not start counting agent: #{inspect(reason)}"
      end
    end
  end

  defp agent_name(config) do
    # Agent names must be atoms; the root differs per test run and per node
    # state directory, so hash it into a unique local name.
    String.to_atom("nix_swarm_counting_#{:erlang.phash2(config.root)}")
  end
end
