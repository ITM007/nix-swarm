defmodule Swarm.Cluster do
  @moduledoc false

  use GenServer

  alias Swarm.NodeName

  @base_retry_ms 1_000
  @max_retry_ms 30_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def live_nodes do
    configured = Swarm.Config.peers()

    current =
      if Node.alive?() do
        [Node.self() | Node.list()]
      else
        []
      end

    configured
    |> Enum.filter(&(&1 in current))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def connect_now do
    GenServer.cast(__MODULE__, :connect)
  end

  @impl true
  def init(state) do
    state =
      %{failed_peers: %{}, monitoring_nodes?: false}
      |> Map.merge(state)
      |> maybe_enable_node_monitoring()

    schedule_connect()
    {:ok, state}
  end

  @impl true
  def handle_cast(:connect, state) do
    {:noreply, connect_peers(state)}
  end

  @impl true
  def handle_info(:connect, state) do
    state = connect_peers(state)
    schedule_connect()
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state), do: {:noreply, clear_failed_peer(state, node)}

  @impl true
  def handle_info({:nodedown, node}, state), do: {:noreply, note_peer_failure(state, node)}

  defp connect_peers(state) do
    state = maybe_enable_node_monitoring(state)

    if Node.alive?() and not NodeName.control_node?(Node.self()) do
      Enum.reduce(Swarm.Config.peers(), state, fn peer, acc ->
        cond do
          peer == Node.self() ->
            acc

          peer in Node.list() ->
            clear_failed_peer(acc, peer)

          not connect_due?(acc, peer) ->
            acc

          Node.connect(peer) ->
            clear_failed_peer(acc, peer)

          true ->
            note_peer_failure(acc, peer)
        end
      end)
    else
      state
    end
  end

  defp schedule_connect do
    Process.send_after(self(), :connect, Swarm.Config.runtime().connect_interval_ms)
  end

  defp maybe_enable_node_monitoring(%{monitoring_nodes?: true} = state), do: state

  defp maybe_enable_node_monitoring(state) do
    if Node.alive?() and not NodeName.control_node?(Node.self()) do
      :net_kernel.monitor_nodes(true)
      %{state | monitoring_nodes?: true}
    else
      state
    end
  end

  defp connect_due?(state, peer) do
    case Map.get(state.failed_peers, peer) do
      nil ->
        true

      %{retry_after_ms: retry_after_ms} ->
        System.monotonic_time(:millisecond) >= retry_after_ms
    end
  end

  defp note_peer_failure(state, peer) do
    attempts =
      state.failed_peers
      |> Map.get(peer, %{})
      |> Map.get(:attempts, 0)

    backoff_ms =
      @base_retry_ms
      |> Kernel.*(trunc(:math.pow(2, attempts)))
      |> min(@max_retry_ms)

    put_in(state.failed_peers[peer], %{
      attempts: attempts + 1,
      retry_after_ms: System.monotonic_time(:millisecond) + backoff_ms
    })
  end

  defp clear_failed_peer(state, peer) do
    %{state | failed_peers: Map.delete(state.failed_peers, peer)}
  end
end
