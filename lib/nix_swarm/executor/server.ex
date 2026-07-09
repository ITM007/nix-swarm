defmodule NixSwarm.Executor.Server do
  @moduledoc """
  Serializes all systemctl calls through a single GenServer.

  Benefits:
  - No concurrent shell-outs racing on systemd
  - Batched unit status checks: one `systemctl show` call for multiple units
  - Short-lived status cache (TTL 200ms) avoids redundant calls within same reconcile cycle
  """

  use GenServer

  @default_timeout_ms 5_000
  @cache_ttl_ms 200

  defmodule State do
    @moduledoc false
    defstruct status_cache: %{}, timeout_ms: 5000
  end

  # --- Public API (delegates to original module for full functionality) ---

  def start_link(opts \\ []) do
    timeout_ms = Keyword.get(opts, :command_timeout_ms, @default_timeout_ms)
    GenServer.start_link(__MODULE__, %State{timeout_ms: timeout_ms}, name: __MODULE__)
  end

  def start_unit(unit), do: GenServer.call(__MODULE__, {:start, unit}, 30_000)
  def stop_unit(unit), do: GenServer.call(__MODULE__, {:stop, unit}, 30_000)
  def restart_unit(unit), do: GenServer.call(__MODULE__, {:restart, unit}, 30_000)

  def unit_status(unit) do
    GenServer.call(__MODULE__, {:unit_status, unit}, 15_000)
  end

  def batch_unit_status(units) when is_list(units) do
    GenServer.call(__MODULE__, {:batch_unit_status, units}, 30_000)
  end

  def unit_logs(unit, lines) do
    GenServer.call(__MODULE__, {:logs, unit, lines}, 15_000)
  end

  def unit_metrics(unit) do
    GenServer.call(__MODULE__, {:metrics, unit}, 15_000)
  end

  def restart_host, do: GenServer.call(__MODULE__, :reboot, 30_000)
  def shutdown_host, do: GenServer.call(__MODULE__, :poweroff, 30_000)

  # --- GenServer callbacks ---

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:start, unit}, _from, state) do
    systemctl(state, ["reset-failed", unit])
    result = systemctl(state, ["start", unit])
    {:reply, result, state}
  end

  def handle_call({:stop, unit}, _from, state) do
    result = systemctl(state, ["stop", unit])
    {:reply, result, state}
  end

  def handle_call({:restart, unit}, _from, state) do
    systemctl(state, ["reset-failed", unit])
    result = systemctl(state, ["restart", unit])
    {:reply, result, state}
  end

  def handle_call({:unit_status, unit}, _from, state) do
    {status, state} = cached_status(state, unit)
    {:reply, {:ok, status}, state}
  end

  def handle_call({:batch_unit_status, units}, _from, state) do
    {statuses, state} = batch_cached_statuses(state, units)
    {:reply, {:ok, statuses}, state}
  end

  def handle_call({:logs, unit, lines}, _from, state) do
    result =
      case shell(state, "journalctl", ["-u", unit, "-n", Integer.to_string(lines), "--no-pager"]) do
        {output, 0} -> {:ok, String.trim_trailing(output)}
        {:error, :timeout} -> {:error, {:journalctl_failed, :timeout, ""}}
        {output, status} -> {:error, {:journalctl_failed, status, output}}
      end

    {:reply, result, state}
  end

  def handle_call({:metrics, unit}, _from, state) do
    properties = [
      "CPUUsageNSec", "MemoryCurrent", "IPIngressBytes", "IPEgressBytes",
      "ActiveEnterTimestampUSec", "StateDirectory", "CacheDirectory",
      "LogsDirectory", "RuntimeDirectory", "ConfigurationDirectory", "RootDirectory"
    ]

    result =
      case shell(state, "systemctl", ["show", unit] ++ Enum.map(properties, &"--property=#{&1}")) do
        {output, 0} ->
          values = parse_properties(output)

          %{
            cpu: %{usage_ns: numeric_property(values, "CPUUsageNSec")},
            memory: %{used: numeric_property(values, "MemoryCurrent")},
            disk: %{used: 0},
            network: %{
              counter: numeric_property(values, "IPIngressBytes") + numeric_property(values, "IPEgressBytes")
            },
            started_at_ns: numeric_property(values, "ActiveEnterTimestampUSec") * 1_000
          }

        _ ->
          %{cpu: %{usage_ns: 0}, memory: %{used: 0}, disk: %{used: 0},
            network: %{counter: 0}, started_at_ns: 0}
      end

    {:reply, result, state}
  end

  def handle_call(:reboot, _from, state) do
    result = systemctl(state, ["reboot"])
    {:reply, result, state}
  end

  def handle_call(:poweroff, _from, state) do
    result = systemctl(state, ["poweroff"])
    {:reply, result, state}
  end

  # --- Private: systemctl wrapper ---

  defp systemctl(state, args) do
    case shell(state, "systemctl", args) do
      {_, 0} -> :ok
      {:error, :timeout} -> {:error, {:systemctl_failed, :timeout, ""}}
      {output, status} -> {:error, {:systemctl_failed, status, output}}
    end
  end

  defp shell(_state, command, args) do
    try do
      System.cmd(command, args, stderr_to_stdout: true, parallelism: false)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  # --- Private: status cache ---

  defp cached_status(state, unit) do
    now = System.monotonic_time(:millisecond)
    case Map.get(state.status_cache, unit) do
      {status, cached_at} when now - cached_at < @cache_ttl_ms ->
        {status, state}
      _ ->
        status = fetch_unit_status(state, unit)
        {status, %{state | status_cache: Map.put(state.status_cache, unit, {status, now})}}
    end
  end

  defp batch_cached_statuses(state, units) do
    now = System.monotonic_time(:millisecond)
    {fresh_units, cached} =
      Enum.reduce(units, {[], %{}}, fn unit, {fresh, acc} ->
        case Map.get(state.status_cache, unit) do
          {status, cached_at} when now - cached_at < @cache_ttl_ms ->
            {fresh, Map.put(acc, unit, status)}
          _ ->
            {[unit | fresh], acc}
        end
      end)

    if fresh_units == [] do
      {cached, state}
    else
      fresh_results = fetch_batch_statuses(state, fresh_units)
      new_cache =
        Enum.reduce(fresh_units, state.status_cache, fn unit, cache ->
          status = Map.get(fresh_results, unit, :unknown)
          Map.put(cache, unit, {status, now})
        end)
      {Map.merge(cached, fresh_results), %{state | status_cache: new_cache}}
    end
  end

  defp fetch_unit_status(state, unit) do
    case shell(state, "systemctl", ["show", unit, "--property=ActiveState", "--property=SubState", "--property=Result"]) do
      {output, 0} -> output |> parse_properties() |> map_unit_status()
      _ -> :unknown
    end
  end

  defp fetch_batch_statuses(state, units) do
    args = ["show"] ++ units ++ ["--property=ActiveState", "--property=SubState", "--property=Result"]
    case shell(state, "systemctl", args) do
      {output, 0} ->
        output
        |> String.split("\n\n", trim: true)
        |> Enum.zip(units)
        |> Enum.reduce(%{}, fn {block, unit}, acc ->
          Map.put(acc, unit, block |> parse_properties() |> map_unit_status())
        end)
      _ ->
        Map.new(units, &{&1, :unknown})
    end
  end

  # --- Private: property parsing (copied from original executor) ---

  defp parse_properties(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, key, parse_value(value))
        _ -> acc
      end
    end)
  end

  defp parse_value(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} -> parsed
      :error -> String.trim(value)
    end
  end

  defp numeric_property(values, key) do
    values |> Map.get(key, 0) |> numeric_value()
  end

  defp numeric_value(value) when is_integer(value), do: value
  defp numeric_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} -> parsed
      :error -> 0
    end
  end

  defp numeric_value(_value), do: 0

  defp map_unit_status(values) do
    active_state = Map.get(values, "ActiveState", "")
    sub_state = Map.get(values, "SubState", "")
    result = Map.get(values, "Result", "")

    cond do
      active_state == "active" -> :running
      active_state == "activating" and restarting_state?(sub_state, result) -> :restarting
      active_state == "activating" -> :starting
      active_state == "deactivating" and restarting_state?(sub_state, result) -> :restarting
      active_state == "deactivating" -> :stopping
      active_state == "failed" -> :failed
      active_state in ["inactive", "dead"] -> :stopped
      true -> :unknown
    end
  end

  defp restarting_state?(sub_state, result) do
    String.contains?(to_string(sub_state), "auto-restart") or
      String.contains?(to_string(result), "start-limit")
  end
end
