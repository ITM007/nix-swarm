defmodule NixSwarm.Executor.Systemd do
  @moduledoc false

  @default_command_timeout_ms 5_000

  def start_unit(unit, config) do
    reset_failed(unit, config)
    systemctl(["start", unit], config)
  end

  def stop_unit(unit, config), do: systemctl(["stop", unit], config)

  def restart_unit(unit, config) do
    reset_failed(unit, config)
    systemctl(["restart", unit], config)
  end

  def unit_status(unit, config) do
    properties = ["ActiveState", "SubState", "Result"]

    case system_cmd(
           "systemctl",
           ["show", unit] ++ Enum.map(properties, &"--property=#{&1}"),
           config
         ) do
      {output, 0} ->
        {:ok, output |> parse_properties() |> map_unit_status()}

      {:error, :timeout} ->
        {:ok, :unknown}

      {_output, _status} ->
        {:ok, :unknown}
    end
  end

  def unit_logs(unit, lines, config) do
    case system_cmd(
           "journalctl",
           ["-u", unit, "-n", Integer.to_string(lines), "--no-pager"],
           config
         ) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {:error, :timeout} -> {:error, {:journalctl_failed, :timeout, ""}}
      {output, status} -> {:error, {:journalctl_failed, status, output}}
    end
  end

  def unit_metrics(unit, config) do
    properties = [
      "CPUUsageNSec",
      "MemoryCurrent",
      "IPIngressBytes",
      "IPEgressBytes",
      "ActiveEnterTimestampUSec",
      "StateDirectory",
      "CacheDirectory",
      "LogsDirectory",
      "RuntimeDirectory",
      "ConfigurationDirectory",
      "RootDirectory"
    ]

    case system_cmd(
           "systemctl",
           ["show", unit] ++ Enum.map(properties, &"--property=#{&1}"),
           config
         ) do
      {output, 0} ->
        values = parse_properties(output)

        %{
          cpu: %{usage_ns: numeric_property(values, "CPUUsageNSec")},
          memory: %{used: numeric_property(values, "MemoryCurrent")},
          disk: %{used: disk_usage_bytes(values, config)},
          network: %{
            counter:
              numeric_property(values, "IPIngressBytes") +
                numeric_property(values, "IPEgressBytes")
          },
          started_at_ns: numeric_property(values, "ActiveEnterTimestampUSec") * 1_000
        }

      {:error, :timeout} ->
        default_metrics()

      {_output, _status} ->
        default_metrics()
    end
  end

  def restart_host(config), do: systemctl(["reboot"], config)
  def shutdown_host(config), do: systemctl(["poweroff"], config)

  defp systemctl(args, config) do
    case system_cmd("systemctl", args, config) do
      {_, 0} -> :ok
      {:error, :timeout} -> {:error, {:systemctl_failed, :timeout, ""}}
      {output, status} -> {:error, {:systemctl_failed, status, output}}
    end
  end

  defp reset_failed(unit, config) do
    system_cmd("systemctl", ["reset-failed", unit], config)
    :ok
  end

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
    values
    |> Map.get(key, 0)
    |> numeric_value()
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
      active_state == "active" ->
        :running

      active_state == "activating" and restarting_state?(sub_state, result) ->
        :restarting

      active_state == "activating" ->
        :starting

      active_state == "deactivating" and restarting_state?(sub_state, result) ->
        :restarting

      active_state == "deactivating" ->
        :stopping

      active_state == "failed" ->
        :failed

      active_state in ["inactive", "dead"] ->
        :stopped

      true ->
        :unknown
    end
  end

  defp restarting_state?(sub_state, result) do
    String.contains?(to_string(sub_state), "auto-restart") or
      String.contains?(to_string(result), "start-limit")
  end

  defp disk_usage_bytes(values, config) do
    values
    |> disk_paths()
    |> Enum.uniq()
    |> Enum.filter(&File.exists?/1)
    |> case do
      [] ->
        0

      paths ->
        case system_cmd("du", ["-sb"] ++ paths, config) do
          {output, 0} -> sum_du_output(output)
          {:error, :timeout} -> 0
          {_output, _status} -> 0
        end
    end
  end

  defp system_cmd(command, args, config) do
    task = Task.async(fn -> System.cmd(command, args, stderr_to_stdout: true) end)

    try do
      Task.await(task, command_timeout_ms(config))
    catch
      :exit, {:timeout, _} ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp command_timeout_ms(config) do
    case Map.get(config, :command_timeout_ms, @default_command_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_command_timeout_ms
    end
  end

  defp disk_paths(values) do
    []
    |> Kernel.++(systemd_named_paths(Map.get(values, "StateDirectory", ""), "/var/lib"))
    |> Kernel.++(systemd_named_paths(Map.get(values, "CacheDirectory", ""), "/var/cache"))
    |> Kernel.++(systemd_named_paths(Map.get(values, "LogsDirectory", ""), "/var/log"))
    |> Kernel.++(systemd_named_paths(Map.get(values, "RuntimeDirectory", ""), "/run"))
    |> Kernel.++(systemd_named_paths(Map.get(values, "ConfigurationDirectory", ""), "/etc"))
    |> maybe_append_root_directory(Map.get(values, "RootDirectory", ""))
  end

  defp systemd_named_paths("", _prefix), do: []

  defp systemd_named_paths(value, prefix) do
    value
    |> to_string()
    |> String.split(" ", trim: true)
    |> Enum.map(fn
      "/" <> _ = absolute -> absolute
      relative -> Path.join(prefix, relative)
    end)
  end

  defp maybe_append_root_directory(paths, "/" <> _ = root_directory), do: [root_directory | paths]
  defp maybe_append_root_directory(paths, _value), do: paths

  defp sum_du_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(0, fn line, acc ->
      case Integer.parse(line) do
        {value, _rest} -> acc + value
        :error -> acc
      end
    end)
  end

  defp default_metrics,
    do: %{
      cpu: %{usage_ns: 0},
      memory: %{used: 0},
      disk: %{used: 0},
      network: %{counter: 0},
      started_at_ns: 0
    }
end
