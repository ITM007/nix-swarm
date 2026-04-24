defmodule Swarm.Executor.Systemd do
  @moduledoc false

  def start_unit(unit, _config) do
    reset_failed(unit)
    systemctl(["start", unit])
  end

  def stop_unit(unit, _config), do: systemctl(["stop", unit])

  def restart_unit(unit, _config) do
    reset_failed(unit)
    systemctl(["restart", unit])
  end

  def unit_status(unit, _config) do
    case System.cmd("systemctl", ["is-active", unit], stderr_to_stdout: true) do
      {"active\n", 0} -> {:ok, :running}
      {_, 0} -> {:ok, :running}
      _ -> {:ok, :stopped}
    end
  end

  def unit_logs(unit, lines, _config) do
    case System.cmd("journalctl", ["-u", unit, "-n", Integer.to_string(lines), "--no-pager"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, status} -> {:error, {:journalctl_failed, status, output}}
    end
  end

  def unit_metrics(unit, _config) do
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

    case System.cmd("systemctl", ["show", unit] ++ Enum.map(properties, &"--property=#{&1}"),
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        values = parse_properties(output)

        %{
          cpu: %{usage_ns: Map.get(values, "CPUUsageNSec", 0)},
          memory: %{used: Map.get(values, "MemoryCurrent", 0)},
          disk: %{used: disk_usage_bytes(values)},
          network: %{
            counter: Map.get(values, "IPIngressBytes", 0) + Map.get(values, "IPEgressBytes", 0)
          },
          started_at_ns: Map.get(values, "ActiveEnterTimestampUSec", 0) * 1_000
        }

      {_output, _status} ->
        default_metrics()
    end
  end

  defp systemctl(args) do
    case System.cmd("systemctl", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:systemctl_failed, status, output}}
    end
  end

  defp reset_failed(unit) do
    System.cmd("systemctl", ["reset-failed", unit], stderr_to_stdout: true)
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

  defp disk_usage_bytes(values) do
    values
    |> disk_paths()
    |> Enum.uniq()
    |> Enum.filter(&File.exists?/1)
    |> case do
      [] ->
        0

      paths ->
        case System.cmd("du", ["-sb"] ++ paths, stderr_to_stdout: true) do
          {output, 0} -> sum_du_output(output)
          {_output, _status} -> 0
        end
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
