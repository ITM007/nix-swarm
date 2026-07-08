defmodule NixSwarm.Watchdog do
  @moduledoc """
  Sends sd_notify watchdog pings to systemd every 15 seconds.

  When systemd starts the service with `Type=notify` and `WatchdogSec=30`,
  the process must send `WATCHDOG=1` at least once every 30 seconds or
  systemd will kill and restart the service.
  """

  use GenServer

  @interval_ms 15_000

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    notify_ready()
    schedule_ping()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:ping, state) do
    notify_watchdog()
    schedule_ping()
    {:noreply, state}
  end

  defp schedule_ping do
    Process.send_after(self(), :ping, @interval_ms)
  end

  defp notify_ready do
    _ = sd_notify("READY=1")
  end

  defp notify_watchdog do
    _ = sd_notify("WATCHDOG=1")
  end

  # sd_notify communicates with systemd via a Unix socket at
  # $NOTIFY_SOCKET. We use a shell call since there's no pure-Elixir
  # sd_notify library and a NIF would be overkill.
  defp sd_notify(msg) do
    socket = System.get_env("NOTIFY_SOCKET")

    if socket do
      System.cmd("systemd-notify", [msg], env: %{"NOTIFY_SOCKET" => socket})
    else
      {:ok, ""}
    end
  rescue
    _ -> {:ok, ""}
  end
end
