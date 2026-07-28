defmodule NixSwarm.Cluster do
  @moduledoc false

  use GenServer

  alias NixSwarm.NodeName

  @base_retry_ms 1_000
  @max_retry_ms 30_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def live_nodes do
    configured = NixSwarm.Config.peers()

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

  @doc "Nodes currently admitted to deterministic service placement."
  def placement_nodes do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :placement_nodes)
    else
      live_nodes()
    end
  catch
    :exit, _reason -> live_nodes()
  end

  @doc "The local node's stabilized membership view."
  def membership do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :membership)
    else
      fallback_membership()
    end
  catch
    :exit, _reason -> fallback_membership()
  end

  @doc "Configured peers expected by safety gates, excluding declared maintenance nodes."
  def required_nodes do
    config = NixSwarm.Config.current()

    Enum.reject(config.peers, fn node ->
      get_in(config, [:nodes, node, :availability]) == :maintenance
    end)
  end

  def connect_now do
    GenServer.cast(__MODULE__, :connect)
  end

  @impl true
  def init(state) do
    state =
      %{
        failed_peers: %{},
        monitoring_nodes?: false,
        membership: initial_membership(),
        transition_timers: %{}
      }
      |> Map.merge(state)
      |> maybe_enable_node_monitoring()
      |> schedule_initial_recovery()

    schedule_connect()
    {:ok, state}
  end

  @impl true
  def handle_cast(:connect, state) do
    {:noreply, connect_peers(state)}
  end

  @impl true
  def handle_call(:placement_nodes, _from, state) do
    nodes =
      state.membership
      |> Enum.filter(fn {_node, entry} -> entry.status in [:up, :suspect] end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    {:reply, nodes, state}
  end

  def handle_call(:membership, _from, state) do
    connected = MapSet.new(live_nodes())
    config = NixSwarm.Config.current()

    view =
      Map.new(state.membership, fn {node, entry} ->
        metadata = Map.get(config.nodes, node, %{})

        {node,
         entry
         |> Map.put(:connected, MapSet.member?(connected, node))
         |> Map.put(:availability, Map.get(metadata, :availability, :active))
         |> Map.drop([:token])}
      end)

    {:reply, view, state}
  end

  @impl true
  def handle_info(:connect, state) do
    state = connect_peers(state)
    schedule_connect()
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    state = clear_failed_peer(state, node)

    if configured_peer?(node) do
      {:noreply, admit_returning_peer(state, node)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    state = note_peer_failure(state, node)

    if configured_peer?(node) do
      {:noreply, suspect_peer(state, node)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:membership_transition, node, :down, token}, state) do
    {:noreply, finish_transition(state, node, :suspect, :down, token)}
  end

  def handle_info({:membership_transition, node, :up, token}, state) do
    {:noreply, finish_transition(state, node, :recovering, :up, token)}
  end

  defp connect_peers(state) do
    state = maybe_enable_node_monitoring(state)

    if Node.alive?() and not NodeName.control_node?(Node.self()) do
      Enum.reduce(NixSwarm.Config.peers(), state, fn peer, acc ->
        cond do
          peer == Node.self() ->
            acc

          peer in Node.list() ->
            acc
            |> clear_failed_peer(peer)
            |> ensure_connected_peer_admitted(peer)

          not connect_due?(acc, peer) ->
            acc

          Node.connect(peer) ->
            acc
            |> clear_failed_peer(peer)
            |> admit_returning_peer(peer)

          true ->
            note_peer_failure(acc, peer)
        end
      end)
    else
      state
    end
  end

  defp schedule_connect do
    Process.send_after(self(), :connect, NixSwarm.Config.runtime().connect_interval_ms)
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

  defp initial_membership do
    connected = MapSet.new(live_nodes())
    now = System.monotonic_time(:millisecond)

    Map.new(NixSwarm.Config.peers(), fn peer ->
      status = if MapSet.member?(connected, peer), do: :recovering, else: :down
      {peer, %{status: status, since_ms: now}}
    end)
  end

  defp schedule_initial_recovery(state) do
    Enum.reduce(state.membership, state, fn
      {peer, %{status: :recovering}}, acc ->
        schedule_transition(acc, peer, :recovering, :up, recovery_stabilization_ms())

      {_peer, _entry}, acc ->
        acc
    end)
  end

  defp fallback_membership do
    connected = MapSet.new(live_nodes())
    config = NixSwarm.Config.current()

    Map.new(config.peers, fn node ->
      {node,
       %{
         status: if(MapSet.member?(connected, node), do: :up, else: :down),
         connected: MapSet.member?(connected, node),
         availability: get_in(config, [:nodes, node, :availability]) || :active
       }}
    end)
  end

  defp ensure_connected_peer_admitted(state, peer) do
    case get_in(state, [:membership, peer, :status]) do
      nil -> put_membership(state, peer, :up)
      :down -> admit_returning_peer(state, peer)
      _status -> state
    end
  end

  defp admit_returning_peer(state, peer) do
    case get_in(state, [:membership, peer, :status]) do
      :suspect ->
        state
        |> cancel_transition(peer)
        |> put_membership(peer, :up)

      :up ->
        state

      :recovering ->
        state

      _status ->
        schedule_transition(state, peer, :recovering, :up, recovery_stabilization_ms())
    end
  end

  defp suspect_peer(state, peer) do
    case get_in(state, [:membership, peer, :status]) do
      :down -> state
      :suspect -> state
      _status -> schedule_transition(state, peer, :suspect, :down, failure_grace_ms())
    end
  end

  defp schedule_transition(state, peer, interim_status, target_status, delay_ms) do
    token = make_ref()

    state =
      state
      |> cancel_transition(peer)
      |> put_membership(peer, interim_status)

    timer =
      Process.send_after(
        self(),
        {:membership_transition, peer, target_status, token},
        delay_ms
      )

    put_in(state.transition_timers[peer], %{timer: timer, token: token})
  end

  defp finish_transition(state, peer, expected_status, target_status, token) do
    case {get_in(state, [:membership, peer, :status]),
          get_in(state, [:transition_timers, peer, :token])} do
      {^expected_status, ^token} ->
        state
        |> update_in([:transition_timers], &Map.delete(&1, peer))
        |> put_membership(peer, target_status)
        |> notify_reconciler()

      _other ->
        state
    end
  end

  defp cancel_transition(state, peer) do
    case Map.pop(state.transition_timers, peer) do
      {nil, timers} ->
        %{state | transition_timers: timers}

      {%{timer: timer}, timers} ->
        Process.cancel_timer(timer)
        %{state | transition_timers: timers}
    end
  end

  defp put_membership(state, peer, status) do
    put_in(state.membership[peer], %{
      status: status,
      since_ms: System.monotonic_time(:millisecond)
    })
  end

  defp notify_reconciler(state) do
    if pid = Process.whereis(NixSwarm.Reconciler), do: send(pid, :membership_changed)
    state
  end

  defp failure_grace_ms, do: NixSwarm.Config.runtime().failure_grace_ms
  defp recovery_stabilization_ms, do: NixSwarm.Config.runtime().recovery_stabilization_ms

  defp configured_peer?(node), do: node in NixSwarm.Config.peers()
end
