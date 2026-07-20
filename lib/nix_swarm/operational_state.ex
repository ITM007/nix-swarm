defmodule NixSwarm.OperationalState do
  @moduledoc """
  Durable, node-local observations derived from the declarative Nix config.

  This store is deliberately not a second source of desired state. It records
  the last configuration generation and reconciliation result so an operator
  can inspect what the agent most recently applied after a BEAM or host restart.
  """

  use GenServer

  @table __MODULE__.Store

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def snapshot do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :snapshot), else: %{}
  end

  def metadata do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :metadata), else: %{}
  end

  def record_reconcile(result) when is_map(result) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:record_reconcile, result})
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    path = state_path()
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(@table, file: String.to_charlist(path), type: :set, auto_save: 1_000) do
      {:ok, @table} ->
        snapshot = load_snapshot()

        {:ok,
         %{
           path: path,
           snapshot: snapshot,
           last_reconciled_at: Map.get(snapshot, :reconciled_at)
         }}

      {:error, reason} ->
        {:stop, {:operational_state_store_failed, path, reason}}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  def handle_call(:metadata, _from, state) do
    snapshot = state.snapshot

    metadata = %{
      path: state.path,
      config_digest: Map.get(snapshot, :config_digest),
      generation: Map.get(snapshot, :generation),
      reconciled_at: state.last_reconciled_at,
      owned_units: snapshot |> Map.get(:owned_units, []) |> length(),
      assignments: snapshot |> Map.get(:assignments, []) |> length(),
      autoscaling_targets: Map.get(snapshot, :autoscaling_targets, %{}),
      membership: Map.get(snapshot, :membership, %{}),
      result_count: snapshot |> Map.get(:results, []) |> length()
    }

    {:reply, metadata, state}
  end

  def handle_call({:record_reconcile, result}, _from, state) do
    runtime = NixSwarm.Config.runtime()
    reconciled_at = System.system_time(:second)

    observations = %{
      config_digest: NixSwarm.Config.digest(),
      generation: runtime.generation,
      owned_units: Map.get(result, :owned_units, []),
      assignments: Map.get(result, :assignments, []),
      results: summarize_results(Map.get(result, :results, [])),
      healthcheck: Map.get(result, :healthcheck, %{}),
      autoscaling_targets: Map.get(result, :autoscaling_targets, %{}),
      membership: Map.get(result, :membership, %{})
    }

    if observations == Map.drop(state.snapshot, [:reconciled_at]) do
      {:reply, :ok, %{state | last_reconciled_at: reconciled_at}}
    else
      snapshot = Map.put(observations, :reconciled_at, reconciled_at)
      :ok = persist(snapshot)
      {:reply, :ok, %{state | snapshot: snapshot, last_reconciled_at: reconciled_at}}
    end
  end

  defp summarize_results(results) do
    Enum.map(results, fn
      {:task_error, reason} -> {:task_error, inspect(reason)}
      {unit, result} -> {unit, result}
      other -> other
    end)
  end

  defp persist(snapshot) do
    with :ok <- :dets.insert(@table, {:snapshot, snapshot}),
         :ok <- :dets.sync(@table) do
      :ok
    end
  end

  defp load_snapshot do
    case :dets.lookup(@table, :snapshot) do
      [{:snapshot, snapshot}] when is_map(snapshot) -> snapshot
      _ -> %{}
    end
  end

  defp state_path do
    root =
      System.get_env("NIX_SWARM_STATE_DIR") ||
        case {Application.get_env(:nix_swarm, :cluster_config),
              NixSwarm.Config.runtime().executor} do
          {nil, _executor} ->
            Path.join(System.tmp_dir!(), "nix-swarm-state-#{System.pid()}")

          {_config, %{adapter: :fake, root: root}} when is_binary(root) ->
            root

          _ ->
            Path.join(System.tmp_dir!(), "nix-swarm-state")
        end

    node =
      if Node.alive?() do
        NixSwarm.Executor.Fake.sanitize_node_name(Node.self())
      else
        "nonode"
      end

    Path.join([root, node, "operational-state.dets"])
  end
end
