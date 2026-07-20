defmodule NixSwarm.Reconciler do
  @moduledoc false

  use GenServer

  alias NixSwarm.Executor
  alias NixSwarm.NodeName
  alias NixSwarm.Placement
  alias NixSwarm.Service

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def reconcile_now do
    GenServer.call(__MODULE__, :reconcile_now, 30_000)
  end

  def local_status do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :local_status, 30_000)
    else
      build_local_status(%{})
    end
  end

  @impl true
  def init(state) do
    previous_owned_units =
      NixSwarm.OperationalState.snapshot()
      |> Map.get(:assignments, [])
      |> Enum.group_by(& &1.service, & &1.unit)
      |> Map.new(fn {service, units} -> {service, MapSet.new(units)} end)

    state =
      %{
        previous_owned_units: previous_owned_units,
        healthcheck_results: %{},
        readiness_counts: %{}
      }
      |> Map.merge(state)

    unless control_node?() do
      schedule_reconcile()
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:reconcile_now, _from, state) do
    {reply, state} = reconcile(state)
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:local_status, _from, state) do
    {:reply, build_local_status(state.healthcheck_results), state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    {_reply, state} = reconcile(state)

    unless control_node?() do
      schedule_reconcile()
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:membership_changed, state), do: reconcile_without_reschedule(state)

  @impl true
  def handle_info(:autoscaling_changed, state), do: reconcile_without_reschedule(state)

  defp reconcile(state) do
    NixSwarm.Telemetry.span(
      [:nix_swarm, :reconcile],
      %{node: Node.self(), config_digest: NixSwarm.Config.digest()},
      fn -> do_reconcile(state) end
    )
  end

  defp do_reconcile(state) do
    if control_node?() do
      {
        %{
          owned_units: [],
          results: [],
          skipped: :control_node
        },
        state
      }
    else
      config = NixSwarm.Config.current()
      live_nodes = NixSwarm.Cluster.live_nodes()
      placement_nodes = NixSwarm.Cluster.placement_nodes()
      owned = Placement.local_units(Node.self(), config, placement_nodes)

      desired_units = owned |> Enum.map(& &1.unit) |> MapSet.new()

      previous_owned_units = Map.get(state, :previous_owned_units, %{})

      previously_owned_units =
        previous_owned_units
        |> Map.values()
        |> Enum.flat_map(&MapSet.to_list/1)

      all_units = Enum.uniq(current_units(config.services) ++ previously_owned_units)

      # Batch-fetch all unit statuses in one systemctl call
      current_statuses =
        if all_units == [] do
          %{}
        else
          case Executor.batch_unit_status(all_units) do
            statuses when is_map(statuses) -> statuses
            {:ok, statuses} when is_map(statuses) -> statuses
            _ -> %{}
          end
        end

      safe_to_stop? = cluster_config_consistent?(live_nodes)

      results =
        Task.Supervisor.async_stream_nolink(
          NixSwarm.TaskSupervisor,
          all_units,
          fn unit ->
            status = Map.get(current_statuses, unit, :unknown)

            cond do
              MapSet.member?(desired_units, unit) and restartable_status?(status) ->
                {unit, Executor.start_unit(unit)}

              not MapSet.member?(desired_units, unit) and stoppable_status?(status) and
                  safe_to_stop? ->
                {unit, Executor.stop_unit(unit)}

              not MapSet.member?(desired_units, unit) and stoppable_status?(status) ->
                {unit, {:error, :config_digest_mismatch}}

              true ->
                {unit, :ok}
            end
          end,
          max_concurrency: 8,
          timeout: 15_000,
          on_timeout: :kill_task,
          ordered: true
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> {:task_error, reason}
        end)

      {healthcheck, readiness_counts} =
        systemd_health(config.services, owned, state.readiness_counts)

      reply = %{
        owned_units: MapSet.to_list(desired_units),
        assignments: owned,
        results: results,
        healthcheck: healthcheck,
        autoscaling_targets: NixSwarm.Autoscaler.targets(),
        membership: NixSwarm.Cluster.membership(),
        destructive_changes_allowed?: safe_to_stop?
      }

      :ok = NixSwarm.OperationalState.record_reconcile(reply)

      {reply,
       %{
         state
         | previous_owned_units:
             remember_owned_units(previous_owned_units, config.services, owned),
           healthcheck_results: healthcheck,
           readiness_counts: readiness_counts
       }}
    end
  end

  defp build_local_status(healthcheck_results) do
    config = NixSwarm.Config.current()
    placement = Placement.plan(config, NixSwarm.Cluster.placement_nodes())
    targets = NixSwarm.Autoscaler.targets()

    Enum.map(config.services, fn service ->
      slots =
        placement[service.name]
        |> Enum.filter(&(&1.owner == Node.self()))
        |> Enum.map(fn slot ->
          status =
            case Executor.unit_status(slot.unit) do
              {:ok, unit_state} -> unit_state
              {:error, _} -> :unknown
            end

          slot
          |> Map.put(:status, status)
          |> Map.put(:metrics, Executor.unit_metrics(slot.unit))
        end)

      desired_replicas =
        if service.autoscaling.enabled,
          do: Map.get(targets, service.name, service.replicas),
          else: service.replicas

      %{
        name: service.name,
        ports: service_ports(service),
        desired_state: if(desired_replicas > 0, do: :running, else: :stopped),
        configured_replicas: service.replicas,
        desired_replicas: desired_replicas,
        autoscaling: service.autoscaling,
        local_owned_slots: Enum.map(slots, & &1.slot),
        units: slots,
        healthcheck: Map.get(healthcheck_results, service.name)
      }
    end)
  end

  defp current_units(services) do
    Enum.flat_map(services, fn service ->
      Enum.map(Service.slots(service, Service.capacity_replicas(service)), fn slot ->
        Service.unit_name(service, slot)
      end)
    end)
  end

  defp remember_owned_units(previous_owned_units, services, owned) do
    owned_by_service =
      owned
      |> Enum.group_by(& &1.service, & &1.unit)
      |> Map.new(fn {service, units} -> {service, MapSet.new(units)} end)

    Enum.reduce(services, previous_owned_units, fn service, acc ->
      case service.replicas do
        0 -> acc
        _ -> Map.put(acc, service.name, Map.get(owned_by_service, service.name, MapSet.new()))
      end
    end)
  end

  defp schedule_reconcile do
    Process.send_after(self(), :reconcile, NixSwarm.Config.runtime().reconcile_interval_ms)
  end

  defp restartable_status?({:ok, status}), do: status not in [:running, :starting, :restarting]
  defp restartable_status?({:error, _reason}), do: true

  defp stoppable_status?({:ok, status}), do: status in [:running, :starting, :restarting]
  defp stoppable_status?({:error, _reason}), do: false

  defp cluster_config_consistent?(live_nodes) do
    digests =
      NixSwarm.RPC.multicall(live_nodes, NixSwarm.API, :config_digest, [])
      |> Enum.map(fn
        {_node, {:ok, digest}} -> digest
        {_node, {:error, _reason}} -> :unreachable
      end)

    :unreachable not in digests and Enum.uniq(digests) == [NixSwarm.Config.digest()]
  end

  defp control_node? do
    Node.alive?() and NodeName.control_node?(Node.self())
  end

  defp service_ports(service) do
    service
    |> Map.get(:settings, %{})
    |> Enum.flat_map(fn {key, value} ->
      if String.contains?(String.downcase(to_string(key)), "port") do
        case value do
          port when is_integer(port) and port > 0 ->
            [port]

          port when is_binary(port) ->
            case Integer.parse(port) do
              {parsed, ""} when parsed > 0 -> [parsed]
              _ -> []
            end

          _ ->
            []
        end
      else
        []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp systemd_health(services, owned, previous_counts) do
    {entries, counts} =
      Enum.map_reduce(services, %{}, fn service, counts_acc ->
        units =
          owned
          |> Enum.filter(&(&1.service == service.name))
          |> Enum.map(& &1.unit)

        statuses = Executor.batch_unit_status(units)

        {unit_counts, counts_acc} =
          Enum.map_reduce(units, counts_acc, fn unit, acc ->
            count =
              if Map.get(statuses, unit) == {:ok, :running},
                do: Map.get(previous_counts, unit, 0) + 1,
                else: 0

            {count, Map.put(acc, unit, count)}
          end)

        entry =
          {service.name,
           %{
             healthy: Enum.all?(unit_counts, &(&1 >= service.readiness.stable_samples)),
             source: :systemd,
             timeout_sec: service.readiness.timeout_sec,
             stable_samples: service.readiness.stable_samples,
             units: Map.new(units, &{&1, Map.get(statuses, &1, {:ok, :unknown})})
           }}

        {entry, counts_acc}
      end)

    {Map.new(entries), counts}
  end

  defp reconcile_without_reschedule(state) do
    {_reply, state} = reconcile(state)
    {:noreply, state}
  end
end
