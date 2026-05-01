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

  def start_local_service(service_name) do
    GenServer.call(__MODULE__, {:set_local_service_mode, service_name, :running}, 30_000)
  end

  def stop_local_service(service_name) do
    GenServer.call(__MODULE__, {:set_local_service_mode, service_name, :stopped}, 30_000)
  end

  def restart_local_service(service_name) do
    GenServer.call(__MODULE__, {:restart_local_service, service_name}, 30_000)
  end

  def local_status do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :local_status, 30_000)
    else
      build_local_status(%{})
    end
  end

  def local_service_modes do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :local_service_modes, 30_000)
    else
      %{}
    end
  end

  @impl true
  def init(state) do
    state =
      %{
        service_modes: %{},
        service_modes_synced?: true,
        monitoring_nodes?: false,
        previous_owned_units: %{}
      }
      |> Map.merge(state)
      |> maybe_enable_node_monitoring()

    unless control_node?() do
      schedule_reconcile()
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:reconcile_now, _from, state) do
    state = maybe_sync_service_modes(state)
    {reply, state} = reconcile(state)
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:local_status, _from, state) do
    state = maybe_sync_service_modes(state)
    {:reply, build_local_status(state.service_modes), state}
  end

  @impl true
  def handle_call(:local_service_modes, _from, state) do
    {:reply, state.service_modes, state}
  end

  @impl true
  def handle_call({:set_local_service_mode, service_name, desired_state}, _from, state) do
    service_name = to_string(service_name)

    case find_service(service_name) do
      nil ->
        {:reply, {:error, :unknown_service}, state}

      _service ->
        service_modes = update_service_mode(state.service_modes, service_name, desired_state)
        next_state = %{state | service_modes: service_modes, service_modes_synced?: true}
        {reply, next_state} = apply_service_mode(next_state, service_name, desired_state)
        {:reply, reply, next_state}
    end
  end

  @impl true
  def handle_call({:restart_local_service, service_name}, _from, state) do
    {:reply, do_restart_local_service(to_string(service_name), state.service_modes), state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    state = maybe_sync_service_modes(state)
    {_reply, state} = reconcile(state)

    unless control_node?() do
      schedule_reconcile()
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    if configured_peer?(node) do
      {:noreply, %{state | service_modes_synced?: false}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    if configured_peer?(node) do
      {:noreply, %{state | service_modes_synced?: false}}
    else
      {:noreply, state}
    end
  end

  defp reconcile(state) do
    if control_node?() do
      {
        %{
          owned_units: [],
          results: [],
          service_modes: state.service_modes,
          skipped: :control_node
        },
        state
      }
    else
      config = NixSwarm.Config.current()
      live_nodes = NixSwarm.Cluster.live_nodes()
      owned = Placement.local_units(Node.self(), config, live_nodes)

      desired_units =
        owned
        |> Enum.reject(fn slot ->
          service_desired_state(state.service_modes, slot.service) == :stopped
        end)
        |> Enum.map(& &1.unit)
        |> MapSet.new()

      previous_owned_units = Map.get(state, :previous_owned_units, %{})
      known_zero_replica_units = zero_replica_units(config.services, previous_owned_units)
      all_units = current_units(config.services) ++ known_zero_replica_units

      results =
        Enum.map(all_units, fn unit ->
          status = Executor.unit_status(unit)

          cond do
            MapSet.member?(desired_units, unit) and restartable_status?(status) ->
              {unit, Executor.start_unit(unit)}

            not MapSet.member?(desired_units, unit) and stoppable_status?(status) ->
              {unit, Executor.stop_unit(unit)}

            true ->
              {unit, :ok}
          end
        end)

      reply = %{
        owned_units: MapSet.to_list(desired_units),
        results: results,
        service_modes: state.service_modes
      }

      {reply,
       %{
         state
         | previous_owned_units:
             remember_owned_units(previous_owned_units, config.services, owned)
       }}
    end
  end

  defp build_local_status(service_modes) do
    config = NixSwarm.Config.current()
    live_nodes = NixSwarm.Cluster.live_nodes()
    placement = Placement.plan(config, live_nodes)

    Enum.map(config.services, fn service ->
      slots =
        placement[service.name]
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

      %{
        name: service.name,
        ports: service_ports(service),
        desired_state: service_desired_state(service_modes, service.name),
        local_owned_slots:
          slots
          |> Enum.filter(&(&1.owner == Node.self()))
          |> Enum.map(& &1.slot),
        units: slots
      }
    end)
  end

  defp do_restart_local_service(service_name, service_modes) do
    cond do
      is_nil(find_service(service_name)) ->
        {:error, :unknown_service}

      service_desired_state(service_modes, service_name) == :stopped ->
        {:error, :service_stopped}

      true ->
        config = NixSwarm.Config.current()
        live_nodes = NixSwarm.Cluster.live_nodes()

        Placement.local_units(Node.self(), config, live_nodes)
        |> Enum.filter(&(&1.service == service_name))
        |> Enum.map(fn slot ->
          {slot.unit, Executor.restart_unit(slot.unit)}
        end)
    end
  end

  defp current_units(services) do
    Enum.flat_map(services, fn service ->
      Enum.map(Service.slots(service), fn slot ->
        Service.unit_name(service, slot)
      end)
    end)
  end

  defp zero_replica_units(services, previous_owned_units) do
    services
    |> Enum.filter(&(&1.replicas == 0))
    |> Enum.flat_map(fn service ->
      service.name
      |> then(&Map.get(previous_owned_units, &1, MapSet.new()))
      |> MapSet.to_list()
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

  defp maybe_enable_node_monitoring(%{monitoring_nodes?: true} = state), do: state

  defp maybe_enable_node_monitoring(state) do
    if Node.alive?() and not control_node?() do
      :net_kernel.monitor_nodes(true)
      %{state | monitoring_nodes?: true}
    else
      state
    end
  end

  defp maybe_sync_service_modes(%{service_modes: service_modes} = state)
       when map_size(service_modes) > 0,
       do: %{state | service_modes_synced?: true}

  defp maybe_sync_service_modes(%{service_modes_synced?: true} = state),
    do: state

  defp maybe_sync_service_modes(state) do
    if control_node?() do
      state
    else
      synced_modes =
        NixSwarm.Cluster.live_nodes()
        |> Enum.reject(&(&1 == Node.self()))
        |> Enum.reduce(%{}, fn node, acc ->
          case :rpc.call(node, __MODULE__, :local_service_modes, [], 5_000) do
            modes when is_map(modes) -> Map.merge(acc, modes)
            _ -> acc
          end
        end)

      %{
        state
        | service_modes: Map.merge(state.service_modes, synced_modes),
          service_modes_synced?: true
      }
    end
  end

  defp apply_service_mode(state, service_name, desired_state) do
    {reconcile_result, state} = reconcile(state)

    reply = %{
      service: service_name,
      desired_state: desired_state,
      reconcile: reconcile_result
    }

    {reply, state}
  end

  defp update_service_mode(service_modes, service_name, :running) do
    Map.delete(service_modes, service_name)
  end

  defp update_service_mode(service_modes, service_name, :stopped) do
    Map.put(service_modes, service_name, :stopped)
  end

  defp service_desired_state(service_modes, service_name) do
    Map.get(service_modes, service_name, :running)
  end

  defp restartable_status?({:ok, status}), do: status not in [:running, :starting, :restarting]
  defp restartable_status?({:error, _reason}), do: true

  defp stoppable_status?({:ok, status}), do: status in [:running, :starting, :restarting]
  defp stoppable_status?({:error, _reason}), do: false

  defp find_service(service_name) do
    Enum.find(NixSwarm.Config.current().services, &(&1.name == service_name))
  end

  defp control_node? do
    Node.alive?() and NodeName.control_node?(Node.self())
  end

  defp configured_peer?(node) do
    node in NixSwarm.Config.peers()
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
end
