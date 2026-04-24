defmodule Swarm.Reconciler do
  @moduledoc false

  use GenServer

  alias Swarm.Executor
  alias Swarm.Placement
  alias Swarm.Service

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def reconcile_now do
    GenServer.call(__MODULE__, :reconcile_now, 30_000)
  end

  def restart_local_service(service_name) do
    GenServer.call(__MODULE__, {:restart_local_service, service_name}, 30_000)
  end

  def local_status do
    config = Swarm.Config.current()
    live_nodes = Swarm.Cluster.live_nodes()
    placement = Placement.plan(config, live_nodes)

    Enum.map(config.services, fn service ->
      slots =
        placement[service.name]
        |> Enum.map(fn slot ->
          status =
            case Executor.unit_status(slot.unit) do
              {:ok, state} -> state
              {:error, _} -> :unknown
            end

          slot
          |> Map.put(:status, status)
          |> Map.put(:metrics, Executor.unit_metrics(slot.unit))
        end)

      %{
        name: service.name,
        ports: service_ports(service),
        local_owned_slots:
          slots
          |> Enum.filter(&(&1.owner == Node.self()))
          |> Enum.map(& &1.slot),
        units: slots
      }
    end)
  end

  @impl true
  def init(state) do
    schedule_reconcile()
    {:ok, state}
  end

  @impl true
  def handle_call(:reconcile_now, _from, state) do
    {:reply, reconcile(), state}
  end

  @impl true
  def handle_call({:restart_local_service, service_name}, _from, state) do
    {:reply, do_restart_local_service(service_name), state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile()
    schedule_reconcile()
    {:noreply, state}
  end

  defp reconcile do
    config = Swarm.Config.current()
    live_nodes = Swarm.Cluster.live_nodes()
    owned = Placement.local_units(Node.self(), config, live_nodes)
    desired_units = MapSet.new(Enum.map(owned, & &1.unit))

    all_units =
      config.services
      |> Enum.flat_map(fn service ->
        Enum.map(Service.slots(service), fn slot ->
          Service.unit_name(service, slot)
        end)
      end)

    results =
      Enum.map(all_units, fn unit ->
        status = Executor.unit_status(unit)

        cond do
          MapSet.member?(desired_units, unit) and status != {:ok, :running} ->
            {unit, Executor.start_unit(unit)}

          not MapSet.member?(desired_units, unit) and status == {:ok, :running} ->
            {unit, Executor.stop_unit(unit)}

          true ->
            {unit, :ok}
        end
      end)

    %{owned_units: MapSet.to_list(desired_units), results: results}
  end

  defp do_restart_local_service(service_name) do
    config = Swarm.Config.current()
    live_nodes = Swarm.Cluster.live_nodes()

    Placement.local_units(Node.self(), config, live_nodes)
    |> Enum.filter(&(&1.service == service_name))
    |> Enum.map(fn slot ->
      {slot.unit, Executor.restart_unit(slot.unit)}
    end)
  end

  defp schedule_reconcile do
    Process.send_after(self(), :reconcile, Swarm.Config.runtime().reconcile_interval_ms)
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
