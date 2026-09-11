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
        },
        service_cpu: service_cpu_rates(previous, current, elapsed_ms),
        node_network: node_network_rates(previous, current, elapsed_ms),
        service_network: service_network_rates(previous, current, elapsed_ms),
        proxy_network: proxy_network_rates(previous, current, elapsed_ms)
      }
    else
      %{
        valid?: false,
        elapsed_ms: max(elapsed_ms, 0),
        cpu: nil,
        network: nil,
        service_cpu: service_cpu_rates(previous, current, elapsed_ms),
        node_network: node_network_rates(previous, current, elapsed_ms),
        service_network: service_network_rates(previous, current, elapsed_ms),
        proxy_network: proxy_network_rates(previous, current, elapsed_ms)
      }
    end
  end

  def delta(_previous, _current),
    do: %{
      valid?: false,
      elapsed_ms: 0,
      cpu: nil,
      network: nil,
      service_cpu: %{},
      node_network: %{},
      service_network: %{},
      proxy_network: %{}
    }

  def rate(previous, current), do: delta(previous, current)

  defp service_cpu_rates(previous, current, elapsed_ms) when elapsed_ms > 0 do
    previous_counters = slot_cpu_counters(value(previous, :services, []) |> List.wrap())
    total_cores = node_total_cores(value(current, :nodes, []) |> List.wrap())

    current
    |> value(:services, [])
    |> List.wrap()
    |> Enum.flat_map(fn service ->
      service = if is_map(service), do: service, else: %{}
      name = value(service, :name, "unknown")

      service
      |> value(:slots, [])
      |> List.wrap()
      |> Enum.map(fn slot -> {NixSwarmWeb.ClusterSnapshot.slot_key(name, slot), slot} end)
    end)
    |> Map.new(fn {key, slot} ->
      {key, service_cpu_pct(key, slot, previous_counters, total_cores, elapsed_ms)}
    end)
  end

  defp service_cpu_rates(_previous, _current, _elapsed_ms), do: %{}

  defp node_network_rates(previous, current, elapsed_ms) do
    previous_nodes = network_nodes(value(previous, :nodes, []) |> List.wrap())

    current
    |> value(:nodes, [])
    |> List.wrap()
    |> Map.new(fn node ->
      name = value(node, :name, "unknown")
      previous_metrics = Map.get(previous_nodes, name, %{})
      current_metrics = value(node, :metrics, %{})
      {name, network_rate(previous_metrics, current_metrics, elapsed_ms)}
    end)
  end

  defp service_network_rates(previous, current, elapsed_ms) do
    previous_slots = network_slots(value(previous, :services, []) |> List.wrap())

    current
    |> value(:services, [])
    |> List.wrap()
    |> Enum.flat_map(fn service ->
      name = value(service, :name, "unknown")

      service
      |> value(:slots, [])
      |> List.wrap()
      |> Enum.map(fn slot ->
        key = NixSwarmWeb.ClusterSnapshot.slot_key(name, slot)
        previous_metrics = Map.get(previous_slots, key, %{})
        current_metrics = value(slot, :metrics, %{})
        {key, network_rate(previous_metrics, current_metrics, elapsed_ms)}
      end)
    end)
    |> Map.new()
  end

  defp proxy_network_rates(previous, current, elapsed_ms) do
    previous_nodes =
      previous
      |> value(:nodes, [])
      |> List.wrap()
      |> Map.new(fn node -> {value(node, :name, "unknown"), value(node, :proxy, %{})} end)

    current
    |> value(:nodes, [])
    |> List.wrap()
    |> Enum.flat_map(fn node ->
      proxy = value(node, :proxy, %{})

      if value(proxy, :enabled?, false) do
        name = value(node, :name, "unknown")
        previous_proxy = Map.get(previous_nodes, name, %{})

        [
          {name,
           network_rate(
             value(previous_proxy, :metrics, %{}),
             value(proxy, :metrics, %{}),
             elapsed_ms
           )}
        ]
      else
        []
      end
    end)
    |> Map.new()
  end

  defp network_nodes(nodes),
    do: Map.new(nodes, &{value(&1, :name, "unknown"), value(&1, :metrics, %{})})

  defp network_slots(services) do
    services
    |> Enum.flat_map(fn service ->
      name = value(service, :name, "unknown")

      service
      |> value(:slots, [])
      |> List.wrap()
      |> Enum.map(fn slot ->
        {NixSwarmWeb.ClusterSnapshot.slot_key(name, slot), value(slot, :metrics, %{})}
      end)
    end)
    |> Map.new()
  end

  defp network_rate(previous_metrics, current_metrics, elapsed_ms) do
    previous_network = value(previous_metrics, :network, %{})
    current_network = value(current_metrics, :network, %{})
    previous_total = network_total(previous_network)
    current_total = network_total(current_network)

    if elapsed_ms > 0 and is_number(previous_total) and is_number(current_total) and
         current_total >= previous_total do
      received = counter_delta(previous_network, current_network, :received)
      transmitted = counter_delta(previous_network, current_network, :transmitted)
      total = current_total - previous_total

      %{
        received: received,
        transmitted: transmitted,
        total: total,
        rate: total / (elapsed_ms / 1_000)
      }
    end
  end

  defp network_total(network) do
    case value(network, :total, nil) do
      total when is_number(total) ->
        total

      _ ->
        case value(network, :counter, nil) do
          counter when is_number(counter) ->
            counter

          _ ->
            received = value(network, :received, nil)
            transmitted = value(network, :transmitted, nil)
            if is_number(received) and is_number(transmitted), do: received + transmitted
        end
    end
  end

  defp counter_delta(previous, current, key) do
    previous_value = value(previous, key, nil)
    current_value = value(current, key, nil)

    if is_number(previous_value) and is_number(current_value) and current_value >= previous_value do
      current_value - previous_value
    else
      nil
    end
  end

  defp slot_cpu_counters(services) do
    services
    |> Enum.flat_map(fn service ->
      service = if is_map(service), do: service, else: %{}
      name = value(service, :name, "unknown")

      service
      |> value(:slots, [])
      |> List.wrap()
      |> Enum.map(fn slot ->
        {NixSwarmWeb.ClusterSnapshot.slot_key(name, slot), slot_usage_ns(slot)}
      end)
    end)
    |> Map.new()
  end

  defp service_cpu_pct(key, slot, previous_counters, total_cores, elapsed_ms) do
    current_usage = slot_usage_ns(slot)

    case Map.fetch(previous_counters, key) do
      {:ok, previous_usage}
      when is_number(previous_usage) and is_number(current_usage) and
             current_usage >= previous_usage ->
        cores = (current_usage - previous_usage) / (elapsed_ms * 1_000_000)
        host_cores = total_cores |> Map.get(value(slot, :owner, nil), 0) |> number_or_zero()

        if host_cores > 0, do: cores / host_cores * 100, else: nil

      _ ->
        nil
    end
  end

  defp slot_usage_ns(slot) do
    slot
    |> value(:metrics, %{})
    |> value(:cpu, %{})
    |> value(:usage_ns, nil)
  end

  defp node_total_cores(nodes) do
    nodes
    |> Enum.map(fn node ->
      node = if is_map(node), do: node, else: %{}
      name = value(node, :name, "unknown")
      cores = node |> value(:metrics, %{}) |> value(:cpu, %{}) |> value(:total, 0)
      {name, number_or_zero(cores)}
    end)
    |> Map.new()
  end

  defp number_or_zero(value) when is_number(value), do: value
  defp number_or_zero(_), do: 0

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
