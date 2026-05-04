defmodule NixSwarm.API do
  @moduledoc false

  alias NixSwarm.ClusterLogs
  alias NixSwarm.Executor
  alias NixSwarm.NodeName
  alias NixSwarm.Placement
  alias NixSwarm.Reconciler

  @version_cache_key {__MODULE__, :version}
  @source_version_digest (
                           source_root = Path.expand("../..", __DIR__)

                           version_sources =
                             [
                               Path.join(source_root, "mix.exs"),
                               Path.join(source_root, "mix.lock")
                             ] ++ Path.wildcard(Path.join(source_root, "lib/**/*.ex"))

                           version_sources
                           |> Enum.sort()
                           |> Enum.reduce(:crypto.hash_init(:sha256), fn path, acc ->
                             relative_path = Path.relative_to(path, source_root)

                             case File.read(path) do
                               {:ok, contents} ->
                                 acc
                                 |> :crypto.hash_update(relative_path)
                                 |> :crypto.hash_update(<<0>>)
                                 |> :crypto.hash_update(contents)

                               {:error, _reason} ->
                                 acc
                             end
                           end)
                           |> :crypto.hash_final()
                           |> Base.encode16(case: :lower)
                           |> binary_part(0, 10)
                         )

  def local_status do
    %{
      node: Node.self(),
      live_nodes: NixSwarm.Cluster.live_nodes(),
      generation: NixSwarm.Config.runtime().generation,
      version: version(),
      services: Reconciler.local_status(),
      metrics: node_metrics(),
      network_info: network_info()
    }
  end

  def version do
    case :persistent_term.get(@version_cache_key, nil) do
      nil ->
        version = build_version()
        :persistent_term.put(@version_cache_key, version)
        version

      version ->
        version
    end
  end

  def cluster_status do
    live_nodes = NixSwarm.Cluster.live_nodes()
    config = NixSwarm.Config.current()

    %{
      queried_node: Node.self(),
      live_nodes: live_nodes,
      placements: Placement.plan(config, live_nodes),
      placement_diagnostics: Placement.diagnostics(config, live_nodes),
      nodes: collect_statuses(live_nodes)
    }
  end

  def cluster_members do
    %{
      queried_node: Node.self(),
      live_nodes: NixSwarm.Cluster.live_nodes(),
      configured_nodes: NixSwarm.Config.peers(),
      deploy_hosts: deploy_hosts()
    }
  end

  def cluster_overview do
    %{
      members: cluster_members(),
      status: cluster_status()
    }
  end

  def reconcile_cluster do
    NixSwarm.Cluster.live_nodes()
    |> Enum.map(fn node ->
      {node, normalize_rpc_result(rpc(node, Reconciler, :reconcile_now, []))}
    end)
  end

  def start_service(service_name) do
    service_name = to_string(service_name)

    NixSwarm.Cluster.live_nodes()
    |> Enum.map(fn node ->
      {node, rpc(node, __MODULE__, :start_local_service, [service_name])}
    end)
  end

  def stop_service(service_name) do
    service_name = to_string(service_name)

    NixSwarm.Cluster.live_nodes()
    |> Enum.map(fn node ->
      {node, rpc(node, __MODULE__, :stop_local_service, [service_name])}
    end)
  end

  def restart_service(service_name) do
    service_name = to_string(service_name)

    NixSwarm.Cluster.live_nodes()
    |> owners_for(service_name)
    |> Enum.map(fn node ->
      {node, rpc(node, __MODULE__, :restart_local_service, [service_name])}
    end)
  end

  def start_service_on_node(node_name, service_name) do
    node_name
    |> normalize_target_node()
    |> rpc(__MODULE__, :start_local_service, [to_string(service_name)])
  end

  def stop_service_on_node(node_name, service_name) do
    node_name
    |> normalize_target_node()
    |> rpc(__MODULE__, :stop_local_service, [to_string(service_name)])
  end

  def restart_service_on_node(node_name, service_name) do
    node_name
    |> normalize_target_node()
    |> rpc(__MODULE__, :restart_local_service, [to_string(service_name)])
  end

  def start_local_service(service_name) do
    Reconciler.start_local_service(service_name)
  end

  def stop_local_service(service_name) do
    Reconciler.stop_local_service(service_name)
  end

  def restart_local_service(service_name) do
    Reconciler.restart_local_service(service_name)
  end

  def restart_machine(node_name) do
    node_name
    |> normalize_target_node()
    |> rpc(__MODULE__, :restart_local_machine, [])
  end

  def shutdown_machine(node_name) do
    node_name
    |> normalize_target_node()
    |> rpc(__MODULE__, :shutdown_local_machine, [])
  end

  def restart_local_machine do
    Executor.restart_host()
  end

  def shutdown_local_machine do
    Executor.shutdown_host()
  end

  def logs(service_name, lines \\ 50) do
    service_name = to_string(service_name)

    NixSwarm.Cluster.live_nodes()
    |> owners_for(service_name)
    |> Enum.map(fn node ->
      logs =
        rpc(node, __MODULE__, :local_logs, [service_name, lines])

      {node, logs}
    end)
  end

  def node_service_logs(node_name, lines \\ 50) do
    node_name
    |> normalize_target_node()
    |> rpc(__MODULE__, :local_node_service_logs, [lines])
  end

  def local_node_service_logs(lines) do
    config = NixSwarm.Config.current()
    live_nodes = NixSwarm.Cluster.live_nodes()

    Placement.local_units(Node.self(), config, live_nodes)
    |> Enum.group_by(& &1.service)
    |> Enum.sort_by(fn {service, _slots} -> service end)
    |> Enum.map(fn {service, slots} ->
      %{
        service: service,
        units:
          slots
          |> Enum.sort_by(& &1.slot)
          |> Enum.map(fn slot ->
            %{
              slot: slot.slot,
              unit: slot.unit,
              status: local_unit_status(slot.unit),
              logs: read_unit_logs(slot.unit, lines),
              metrics: Executor.unit_metrics(slot.unit)
            }
          end)
      }
    end)
  end

  def cluster_logs(node_name, lines \\ 50) do
    node_name
    |> normalize_target_node()
    |> rpc(__MODULE__, :local_cluster_logs, [lines])
  end

  def local_cluster_logs(lines) do
    case NixSwarm.Config.runtime().executor.adapter do
      :systemd ->
        case System.cmd(
               "journalctl",
               ["-u", "nix-swarmd", "-n", Integer.to_string(lines), "--no-pager"],
               stderr_to_stdout: true
             ) do
          {output, 0} -> output |> sanitize_cluster_logs() |> String.trim()
          {output, _status} -> output |> sanitize_cluster_logs() |> String.trim()
        end

      _ ->
        fake_cluster_logs(lines)
    end
  end

  def local_logs(service_name, lines) do
    config = NixSwarm.Config.current()
    live_nodes = NixSwarm.Cluster.live_nodes()

    Placement.local_units(Node.self(), config, live_nodes)
    |> Enum.filter(&(&1.service == service_name))
    |> Enum.map(fn slot ->
      logs =
        case Executor.unit_logs(slot.unit, lines) do
          {:ok, output} -> output
          {:error, reason} -> inspect(reason)
        end

      %{slot: slot.slot, unit: slot.unit, logs: logs}
    end)
  end

  def node_metrics do
    try do
      cpu_total = logical_processors_available()
      cpu_pct = normalize_percent(:cpu_sup.util())
      cpu_used = cpu_total * cpu_pct / 100.0

      mem_data = :memsup.get_system_memory_data()
      total_mem = memory_data_value(mem_data, :total_memory)
      free_mem = memory_data_value(mem_data, :free_memory)
      used_mem = max(total_mem - free_mem, 0)
      mem_pct = ratio_percent(used_mem, total_mem)

      {disk_used, disk_total} = disk_usage()
      disk_pct = ratio_percent(disk_used, disk_total)

      network = network_counters()

      {uptime_ms, _} = :erlang.statistics(:wall_clock)
      uptime_sec = div(uptime_ms, 1000)

      %{
        cpu: %{
          used: cpu_used,
          total: cpu_total,
          pct: round(cpu_pct)
        },
        memory: %{
          used: used_mem,
          total: total_mem,
          pct: mem_pct
        },
        disk: %{
          used: disk_used,
          total: disk_total,
          pct: disk_pct
        },
        network: network,
        uptime: uptime_sec
      }
    rescue
      _ ->
        %{
          cpu: %{used: 0.0, total: 0, pct: 0},
          memory: %{used: 0, total: 0, pct: 0},
          disk: %{used: 0, total: 0, pct: 0},
          network: %{received: 0, transmitted: 0, total: 0},
          uptime: 0
        }
    end
  end

  def network_info do
    ips =
      case :inet.getifaddrs() do
        {:ok, interfaces} ->
          Enum.flat_map(interfaces, fn {_name, opts} ->
            opts
            |> Keyword.get_values(:addr)
            |> Enum.map(fn
              addr when tuple_size(addr) == 4 -> :inet.ntoa(addr) |> to_string()
              _ -> nil
            end)
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(&(&1 == "127.0.0.1"))
          |> Enum.uniq()

        _ ->
          []
      end

    %{
      ips: ips,
      ports: [22, 80, 443, 4369, 4370]
    }
  end

  defp owners_for(live_nodes, service_name) do
    NixSwarm.Config.current()
    |> Placement.plan(live_nodes)
    |> Map.get(service_name, [])
    |> Enum.map(& &1.owner)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp collect_statuses(nodes) do
    Enum.map(nodes, fn node ->
      status =
        if node == Node.self() do
          local_status()
        else
          rpc(node, __MODULE__, :local_status, [])
        end

      {node, status}
    end)
  end

  defp rpc(node, module, function, args) do
    if node == Node.self() do
      apply(module, function, args)
    else
      :rpc.call(node, module, function, args, 5_000)
    end
  end

  defp normalize_rpc_result({:badrpc, reason}), do: {:error, {:rpc_failed, reason}}
  defp normalize_rpc_result(result), do: result

  defp normalize_target_node(node) when is_atom(node), do: node

  defp normalize_target_node(node) when is_binary(node) do
    NodeName.resolve_existing!(
      node,
      [Node.self() | NixSwarm.Cluster.live_nodes() ++ NixSwarm.Config.peers()],
      "target node"
    )
  end

  defp local_unit_status(unit) do
    case Executor.unit_status(unit) do
      {:ok, status} -> status
      {:error, _reason} -> :unknown
    end
  end

  defp read_unit_logs(unit, lines) do
    case Executor.unit_logs(unit, lines) do
      {:ok, output} -> output
      {:error, reason} -> inspect(reason)
    end
  end

  defp fake_cluster_logs(lines) do
    services =
      Reconciler.local_status()
      |> Enum.flat_map(fn service ->
        Enum.map(service.units, fn unit ->
          "#{service.name} #{unit.unit} #{unit.status}"
        end)
      end)
      |> Enum.take(lines)

    [
      "#{DateTime.utc_now() |> DateTime.to_iso8601()} fake cluster runtime",
      "node=#{Node.self()} generation=#{NixSwarm.Config.runtime().generation}"
      | services
    ]
    |> Enum.join("\n")
    |> String.trim()
  end

  defp sanitize_cluster_logs(output) do
    ClusterLogs.sanitize(output)
  end

  defp deploy_hosts do
    NixSwarm.Config.current().nodes
    |> Enum.reduce(%{}, fn {node, attrs}, acc ->
      case Map.get(attrs, :deploy_host) do
        nil -> acc
        host -> Map.put(acc, node, host)
      end
    end)
  end

  defp build_version do
    "#{NixSwarm.release_label()}-#{@source_version_digest}"
  end

  defp logical_processors_available do
    case :erlang.system_info(:logical_processors_available) do
      value when is_integer(value) and value > 0 ->
        value

      _ ->
        case :erlang.system_info(:logical_processors) do
          value when is_integer(value) and value > 0 -> value
          _ -> 1
        end
    end
  end

  defp normalize_percent(value) when is_integer(value), do: value |> max(0) |> min(100)
  defp normalize_percent(value) when is_float(value), do: value |> max(0.0) |> min(100.0)
  defp normalize_percent(_value), do: 0

  defp ratio_percent(_used, total) when total <= 0, do: 0

  defp ratio_percent(used, total) do
    round(used / total * 100)
  end

  defp memory_data_value(data, key) do
    data
    |> Keyword.get(key, 0)
  end

  defp disk_usage do
    disk =
      :disksup.get_disk_data()
      |> Enum.filter(fn {_mount, total_kb, _pct} -> total_kb > 0 end)
      |> preferred_disk()

    case disk do
      {_mount, total_kb, used_pct} ->
        total = total_kb * 1024
        used = round(total * normalize_percent(used_pct) / 100)
        {used, total}

      nil ->
        {0, 0}
    end
  end

  defp preferred_disk(disks) do
    Enum.find(disks, fn {mount, _total_kb, _pct} -> to_string(mount) == "/" end) ||
      Enum.max_by(disks, fn {_mount, total_kb, _pct} -> total_kb end, fn -> nil end)
  end

  defp network_counters do
    stats =
      candidate_network_interfaces()
      |> Enum.map(&network_interface_stats/1)
      |> Enum.reject(&is_nil/1)

    Enum.reduce(stats, %{received: 0, transmitted: 0, total: 0}, fn stat, acc ->
      %{
        received: acc.received + stat.received,
        transmitted: acc.transmitted + stat.transmitted,
        total: acc.total + stat.total
      }
    end)
  end

  defp candidate_network_interfaces do
    names =
      case :inet.getifaddrs() do
        {:ok, interfaces} ->
          interfaces
          |> Enum.flat_map(fn {name, opts} ->
            flags = Keyword.get(opts, :flags, [])

            if :loopback in flags do
              []
            else
              [to_string(name)]
            end
          end)
          |> Enum.uniq()

        _ ->
          []
      end

    physical =
      Enum.filter(names, fn name ->
        File.exists?("/sys/class/net/#{name}/device")
      end)

    if physical == [], do: names, else: physical
  end

  defp network_interface_stats(name) do
    with {:ok, received} <- read_sysfs_integer("/sys/class/net/#{name}/statistics/rx_bytes"),
         {:ok, transmitted} <- read_sysfs_integer("/sys/class/net/#{name}/statistics/tx_bytes") do
      speed_mbps =
        case read_sysfs_integer("/sys/class/net/#{name}/speed") do
          {:ok, value} when value > 0 -> value
          _ -> 0
        end

      %{
        received: received,
        transmitted: transmitted,
        total: div(speed_mbps * 1_000_000, 8)
      }
    else
      _ -> nil
    end
  end

  defp read_sysfs_integer(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {value, _rest} -> {:ok, value}
          :error -> :error
        end

      {:error, _reason} ->
        :error
    end
  end
end
