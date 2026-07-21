defmodule NixSwarm.Watchdog do
  @moduledoc """
  Sends sd_notify watchdog pings to systemd every 15 seconds.

  When systemd starts the service with `Type=notify` and `WatchdogSec=30`,
  the process must send `WATCHDOG=1` at least once every 30 seconds or
  systemd will kill and restart the service.
  """

  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    notify_ready()
    interval_ms = watchdog_interval_ms()
    schedule_ping(interval_ms)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:ping, state) do
    notify_watchdog()
    schedule_ping(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    _ = sd_notify(["--stopping", "--status=Nix-Swarm stopping"])
    :ok
  end

  defp schedule_ping(interval_ms) do
    Process.send_after(self(), :ping, interval_ms)
  end

  defp notify_ready do
    _ = sd_notify(["--ready", "--status=Nix-Swarm agent ready"])
  end

  defp notify_watchdog do
    # `systemd-notify` accepts arbitrary sd_notify assignments as positional
    # arguments. It has `--ready` and `--stopping` convenience flags, but no
    # `--watchdog` option on supported systemd releases.
    _ = sd_notify(["WATCHDOG=1", "--status=Nix-Swarm agent healthy"])
  end

  defp sd_notify(args) do
    socket = System.get_env("NOTIFY_SOCKET")
    executable = System.get_env("NIX_SWARM_SYSTEMD_NOTIFY") || "systemd-notify"

    if socket do
      System.cmd(executable, args,
        env: [{"NOTIFY_SOCKET", socket}],
        stderr_to_stdout: true
      )
    else
      {:ok, ""}
    end
  rescue
    _ -> {:ok, ""}
  end

  defp watchdog_interval_ms do
    case Integer.parse(System.get_env("WATCHDOG_USEC") || "") do
      {microseconds, ""} when microseconds > 0 -> max(div(microseconds, 2_000), 1_000)
      _ -> 15_000
    end
  end
end
