defmodule Swarm.Cluster do
  @moduledoc false

  use GenServer

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
    if Node.alive?() do
      :net_kernel.monitor_nodes(true)
    end

    schedule_connect()
    {:ok, state}
  end

  @impl true
  def handle_cast(:connect, state) do
    connect_peers()
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, state) do
    connect_peers()
    schedule_connect()
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, _node}, state), do: {:noreply, state}

  @impl true
  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  defp connect_peers do
    if Node.alive?() do
      for peer <- Swarm.Config.peers(), peer != Node.self() do
        Node.connect(peer)
      end
    end
  end

  defp schedule_connect do
    Process.send_after(self(), :connect, Swarm.Config.runtime().connect_interval_ms)
  end
end
