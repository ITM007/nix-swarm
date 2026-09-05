defmodule NixSwarmWeb.MetricHistory do
  @moduledoc """
  Bounded in-memory metric samples and monotonic counter deltas.

  The history is intentionally process-local. A counter regression or a sample
  with a non-advancing timestamp is not turned into a misleading rate.
  """

  @default_size 120

  @type t :: %{max_size: pos_integer(), samples: list()}

  @doc "Creates an empty bounded metric history."
  def new(max_size \\ @default_size)

  def new(max_size) when is_integer(max_size) and max_size > 0 do
    %{max_size: max_size, samples: []}
  end

  def new(_), do: new()

  @doc "Appends one sample and drops the oldest samples past the bound."
  def push(%{max_size: max_size, samples: samples} = history, sample) do
    %{history | samples: Enum.take(samples ++ [sample], -max_size)}
  end

  def push(_history, sample), do: push(new(), sample)

  def append(history, sample), do: push(history, sample)
  def samples(%{samples: samples}), do: samples
  def samples(_), do: []
  def values(history), do: samples(history)

  @doc "Returns safe CPU/network counter deltas between two normalized snapshots."
  def delta(previous, current) when is_map(previous) and is_map(current) do
    previous_ms = timestamp_ms(previous)
    current_ms = timestamp_ms(current)
    elapsed_ms = current_ms - previous_ms
    previous_metrics = cluster_metrics(previous)
    current_metrics = cluster_metrics(current)

    previous_cpu = cpu_counter(previous_metrics.cpu)
    current_cpu = cpu_counter(current_metrics.cpu)

    valid? =
      elapsed_ms > 0 and
        is_number(previous_cpu) and
        is_number(current_cpu) and
        current_cpu >= previous_cpu and
        counters_advance?(previous_metrics.network, current_metrics.network, [
          :received,
          :transmitted
        ])

    if valid? do
      cpu_used = current_cpu - previous_cpu

      received =
        counter(current_metrics.network, :received) - counter(previous_metrics.network, :received)

      transmitted =
        counter(current_metrics.network, :transmitted) -
          counter(previous_metrics.network, :transmitted)

      seconds = elapsed_ms / 1_000

      %{
        valid?: true,
        elapsed_ms: elapsed_ms,
        cpu: %{
          used: cpu_used,
          total: value(current_metrics.cpu, :total, 0),
          rate: cpu_used / seconds
        },
        network: %{
          received: received,
          transmitted: transmitted,
          rate: (received + transmitted) / seconds
        }
      }
    else
      %{valid?: false, elapsed_ms: max(elapsed_ms, 0), cpu: nil, network: nil}
    end
  end

  def delta(_previous, _current), do: %{valid?: false, elapsed_ms: 0, cpu: nil, network: nil}

  def rate(previous, current), do: delta(previous, current)

  defp cluster_metrics(snapshot) do
    snapshot
    |> value(:metrics, %{})
    |> value(:cluster, %{})
    |> then(fn cluster ->
      %{cpu: value(cluster, :cpu, %{}), network: value(cluster, :network, %{})}
    end)
  end

  defp counters_advance?(previous, current, keys) do
    Enum.all?(keys, fn key ->
      previous_value = value(previous, key, nil)
      current_value = value(current, key, nil)
      is_number(previous_value) and is_number(current_value) and current_value >= previous_value
    end)
  end

  defp counter(metrics, key), do: value(metrics, key, 0)

  defp cpu_counter(metrics) do
    case value(metrics, :used, nil) do
      value when is_number(value) -> value
      _ -> value(metrics, :usage_ns, nil)
    end
  end

  defp value(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value(_map, _key, default), do: default

  defp timestamp_ms(snapshot) do
    case value(snapshot, :captured_at_ms, nil) do
      value when is_integer(value) ->
        value

      _ ->
        case value(snapshot, :captured_at, nil) do
          %DateTime{} = date_time -> DateTime.to_unix(date_time, :millisecond)
          _ -> 0
        end
    end
  end
end
