defmodule NixSwarmWeb.Format do
  @moduledoc "Pure formatting helpers used by views and exports."

  @units ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]

  @doc "Formats a byte count with IEC units; unknown stays explicit."
  def bytes(value) when is_integer(value) and value >= 0, do: format_bytes_value(value)
  def bytes(value) when is_float(value) and value >= 0, do: format_bytes_value(value)
  def bytes(_), do: "unknown"

  @doc "Formats a byte-per-second rate with IEC units."
  def rate(value) when is_integer(value) and value >= 0, do: "#{bytes(value)}/s"
  def rate(value) when is_float(value) and value >= 0, do: "#{bytes(value)}/s"
  def rate(_), do: "unknown"

  @doc "Formats a duration in whole seconds."
  def duration(seconds) when is_integer(seconds) and seconds >= 0 do
    {days, remainder} = div_rem(seconds, 86_400)
    {hours, remainder} = div_rem(remainder, 3_600)
    {minutes, seconds} = div_rem(remainder, 60)

    [{days, "d"}, {hours, "h"}, {minutes, "m"}, {seconds, "s"}]
    |> Enum.filter(fn {value, _unit} -> value > 0 end)
    |> case do
      [] -> "0s"
      parts -> Enum.map_join(parts, " ", fn {value, unit} -> "#{value}#{unit}" end)
    end
  end

  def duration(_), do: "unknown"

  @doc "Formats a duration in milliseconds using compact stable units."
  def duration_ms(value) when is_integer(value) and value >= 0 do
    cond do
      value < 1_000 -> "#{value}ms"
      value < 60_000 -> "#{trim_number(value / 1_000)}s"
      value < 3_600_000 -> "#{trim_number(value / 60_000)}m"
      true -> "#{trim_number(value / 3_600_000)}h"
    end
  end

  def duration_ms(_), do: "unknown"

  @doc "Formats a percentage to one decimal place while preserving unknown values."
  def percent(value) when is_integer(value) or is_float(value), do: "#{fixed_number(value)}%"
  def percent(_), do: "unknown"

  @doc "Formats CPU usage as a percentage, converting systemd CPU time when possible."
  def cpu_percent(value, now_ns \\ System.system_time(:nanosecond))

  def cpu_percent(%{pct: value}, _now_ns) when is_number(value), do: percent(value)

  def cpu_percent(%{used: used, total: total}, _now_ns)
      when is_number(used) and is_number(total) and total > 0,
      do: percent(used / total * 100)

  def cpu_percent(%{usage_ns: usage_ns, started_at_ns: started_at_ns}, now_ns)
      when is_number(usage_ns) and is_number(started_at_ns) and is_number(now_ns) do
    elapsed_ns = now_ns - started_at_ns

    if elapsed_ns > 0,
      do: percent(usage_ns / elapsed_ns * 100),
      else: "unknown"
  end

  def cpu_percent(value, _now_ns) when is_integer(value) or is_float(value), do: percent(value)
  def cpu_percent(_value, _now_ns), do: "unknown"

  def format_bytes(value), do: bytes(value)
  def format_duration(value), do: duration(value)
  def format_percentage(value), do: percent(value)

  defp format_bytes_value(value) do
    {scaled, unit} = scale_bytes(value, 0)
    "#{trim_number(scaled)} #{unit}"
  end

  defp scale_bytes(value, index) when value >= 1_024 and index < length(@units) - 1,
    do: scale_bytes(value / 1_024, index + 1)

  defp scale_bytes(value, index), do: {value, Enum.at(@units, index)}

  defp trim_number(value) when is_integer(value), do: Integer.to_string(value)

  defp trim_number(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp fixed_number(value) when is_integer(value), do: "#{value}.0"

  defp fixed_number(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp div_rem(value, divisor), do: {div(value, divisor), rem(value, divisor)}
end
