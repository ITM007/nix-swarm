defmodule NixSwarm.API do
  @moduledoc """
  Internal API surface for trusted Nix-Swarm peers.

  Agents call this module locally and across authenticated distributed Erlang.
  Operator tools cannot invoke it directly: `NixSwarm.QueryServer` exposes a small,
  read-only allowlist over a local Unix socket and SSH.
  """

  alias NixSwarm.ClusterLogs
  alias NixSwarm.Executor
  alias NixSwarm.NodeName
  alias NixSwarm.Placement
  alias NixSwarm.Reconciler

  @version_cache_key {__MODULE__, :version}
  @max_log_lines 1_000
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

  @doc """
  Returns the local node's status: node identity, live peer set, generation, version,
  service status, host metrics, and network info.
  """
  def local_status do
    build_version = version()
    config = NixSwarm.Config.current()
    node_metadata = Map.get(config.nodes, Node.self(), %{})

    %{
      node: Node.self(),
      availability: Map.get(node_metadata, :availability, :active),
      live_nodes: NixSwarm.Cluster.live_nodes(),
      membership: NixSwarm.Cluster.membership(),
      generation: config.runtime.generation,
      config_digest: NixSwarm.Config.digest_for(config),
      version: build_version,
      build_version: build_version,
      release_version: NixSwarm.release_label(),
      services: Reconciler.local_status(),
      operational_state: NixSwarm.OperationalState.metadata(),
      metrics: node_metrics(),
      network_info: network_info()
    }
  end

  @doc "Returns the node's build version, cached in :persistent_term."
  def version do
    case :persistent_term.get(@version_cache_key, nil) do
      nil ->
        version = build_version()

        try do
          :persistent_term.put(@version_cache_key, version)
        rescue
          _ -> :ok
        end

        version

      version ->
        version
    end
  end

  @doc "Returns the immutable desired-state digest used for safe reconciliation gates."
  def config_digest, do: NixSwarm.Config.digest()

  @doc "Returns cluster-wide status: placement plan, diagnostics, and per-node status."
  def cluster_status do
    live_nodes = NixSwarm.Cluster.live_nodes()
    placement_nodes = NixSwarm.Cluster.placement_nodes()
    config = NixSwarm.Config.current()
    nodes = collect_statuses(live_nodes)
    config_digests = node_config_digests(nodes)

    %{
      queried_node: Node.self(),
      live_nodes: live_nodes,
      placement_nodes: placement_nodes,
      placements: Placement.plan(config, placement_nodes),
      placement_diagnostics:
        Placement.diagnostics(config, placement_nodes) ++
          config_consistency_diagnostics(config_digests),
      config_digests: config_digests,
      config_consistent?: config_digests |> Map.values() |> Enum.uniq() |> length() <= 1,
      nodes: nodes
    }
  end

  @doc "Returns the cluster membership view: live nodes, configured peers, and deploy hosts."
  def cluster_members do
    %{
      queried_node: Node.self(),
      live_nodes: NixSwarm.Cluster.live_nodes(),
      placement_nodes: NixSwarm.Cluster.placement_nodes(),
      membership: NixSwarm.Cluster.membership(),
      required_nodes: NixSwarm.Cluster.required_nodes(),
      configured_nodes: NixSwarm.Config.peers(),
      deploy_hosts: deploy_hosts(),
      deploy_configurations: deploy_configurations()
    }
  end

  @doc "Returns the combined cluster overview (members + status) for the TUI dashboard."
  def cluster_overview do
    %{
      members: cluster_members(),
      status: cluster_status(),
      ingress: ingress_info()
    }
  end

  @doc "Returns one bounded, partial-failure-safe payload for an operator refresh."
  def operator_snapshot(selected_service, selected_node, lines) do
    overview = cluster_overview()
    live_nodes = overview.members.live_nodes

    service_logs =
      if is_binary(selected_service) and selected_service != "",
        do: logs(selected_service, lines),
        else: []

    node_service_logs =
      if is_atom(selected_node),
        do:
          normalize_snapshot_rpc(
            rpc(selected_node, __MODULE__, :local_node_service_logs, [lines])
          ),
        else: nil

    cluster_log_results =
      NixSwarm.RPC.multicall(live_nodes, __MODULE__, :local_cluster_logs, [lines])

    cluster_logs =
      Map.new(cluster_log_results, fn
        {node, {:ok, output}} -> {node, output}
        {node, {:error, reason}} -> {node, {:error, reason}}
      end)

    errors =
      cluster_logs
      |> Enum.flat_map(fn
        {node, {:error, reason}} -> [%{scope: :cluster_logs, node: node, reason: inspect(reason)}]
        {_node, _output} -> []
      end)
      |> maybe_add_snapshot_error(:node_service_logs, selected_node, node_service_logs)

    %{
      overview: overview,
      service_logs: service_logs,
      selected_node_service_logs: node_service_logs,
      selected_node_cluster_logs:
        if(is_atom(selected_node), do: Map.get(cluster_logs, selected_node, ""), else: ""),
      cluster_logs: cluster_logs,
      errors: errors
    }
  end

  @doc "Returns ingress configuration from the current node's runtime config."
  def ingress_info do
    config = NixSwarm.Config.current()
    Map.get(config, :ingress, %{sites: %{}})
  end

  @doc "Triggers immediate reconciliation across all live cluster nodes."
  def reconcile_cluster do
    NixSwarm.Cluster.live_nodes()
    |> Enum.map(fn node ->
      {node, normalize_rpc_result(rpc(node, Reconciler, :reconcile_now, []))}
    end)
  end

  @doc "Fetches service logs from owning nodes."
  def logs(service_name, lines \\ 50) do
    service_name = to_string(service_name)
    lines = normalize_log_lines(lines)

    NixSwarm.Cluster.live_nodes()
    |> owners_for(service_name)
    |> Enum.map(fn node ->
      logs =
        rpc(node, __MODULE__, :local_logs, [service_name, lines])

      {node, logs}
    end)
  end

  @doc "Fetches node-level service logs from a specific node."
  def node_service_logs(node_name, lines \\ 50) do
    node_name
    |> normalize_target_node()
    |> rpc(__MODULE__, :local_node_service_logs, [normalize_log_lines(lines)])
  end

  def local_node_service_logs(lines) do
    lines = normalize_log_lines(lines)
    config = NixSwarm.Config.current()
    placement_nodes = NixSwarm.Cluster.placement_nodes()

    Placement.local_units(Node.self(), config, placement_nodes)
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

  @doc "Fetches cluster-level logs from a specific node."
  def cluster_logs(node_name, lines \\ 50) do
    node_name
    |> normalize_target_node()
    |> rpc(__MODULE__, :local_cluster_logs, [normalize_log_lines(lines)])
  end

  def local_cluster_logs(lines) do
    lines = normalize_log_lines(lines)

    case NixSwarm.Config.runtime().executor.adapter do
      :systemd ->
        case Executor.unit_logs("nix-swarmd.service", lines) do
          {:ok, output} -> output |> sanitize_cluster_logs() |> String.trim()
          {:error, reason} -> reason |> inspect() |> sanitize_cluster_logs() |> String.trim()
        end

      _ ->
        fake_cluster_logs(lines)
    end
  end

  def local_logs(service_name, lines) do
    lines = normalize_log_lines(lines)
    config = NixSwarm.Config.current()
    placement_nodes = NixSwarm.Cluster.placement_nodes()

    Placement.local_units(Node.self(), config, placement_nodes)
    |> Enum.filter(&(&1.service == service_name))
    |> Enum.map(fn slot ->
      logs =
        case Executor.unit_logs(slot.unit, lines) do
          {:ok, output} -> ClusterLogs.terminal_safe(output)
          {:error, reason} -> reason |> inspect() |> ClusterLogs.terminal_safe()
        end

      %{slot: slot.slot, unit: slot.unit, logs: logs}
    end)
  end

  @doc "Returns host-level resource metrics (CPU, memory, disk, network, uptime)."
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

  @doc "Returns local network interface information (IPs and common ports)."
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
      ports: [
        environment_port("ERL_EPMD_PORT", 4369),
        environment_port("NIX_SWARM_DISTRIBUTION_PORT", 4370)
      ]
    }
  end

  defp environment_port(name, default) do
    case Integer.parse(System.get_env(name) || "") do
      {port, ""} when port in 1..65_535 -> port
      _ -> default
    end
  end

  defp normalize_snapshot_rpc({:badrpc, reason}), do: {:error, reason}
  defp normalize_snapshot_rpc(value), do: value

  defp maybe_add_snapshot_error(errors, _scope, _node, {:error, reason}) do
    [%{scope: :node_service_logs, reason: inspect(reason)} | errors]
  end

  defp maybe_add_snapshot_error(errors, _scope, _node, _value), do: errors

  defp owners_for(live_nodes, service_name) do
    NixSwarm.Config.current()
    |> Placement.plan(live_nodes)
    |> Map.get(service_name, [])
    |> Enum.map(& &1.owner)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp collect_statuses(nodes) do
    NixSwarm.RPC.multicall(nodes, __MODULE__, :local_status, [])
    |> Enum.map(fn
      {node, {:ok, status}} ->
        {node, status}

      {node, {:error, reason}} ->
        {node,
         %{
           node: node,
           live_nodes: [],
           error: :node_unreachable,
           reason: inspect(reason)
         }}
    end)
  end

  defp node_config_digests(nodes) do
    Map.new(nodes, fn {node, status} -> {node, Map.get(status, :config_digest, "unknown")} end)
  end

  defp config_consistency_diagnostics(config_digests) do
    if config_digests |> Map.values() |> Enum.uniq() |> length() <= 1 do
      []
    else
      [
        %{
          service: "cluster",
          severity: :error,
          reason: :config_digest_mismatch,
          config_digests: config_digests,
          message: "cluster nodes are running different desired-state configurations"
        }
      ]
    end
  end

  defp rpc(node, module, function, args) do
    case NixSwarm.RPC.call(node, module, function, args) do
      {:ok, result} -> result
      {:error, reason} -> {:badrpc, reason}
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

  defp normalize_log_lines(lines) when is_integer(lines) do
    lines |> max(1) |> min(@max_log_lines)
  end

  defp normalize_log_lines(_lines), do: 50

  defp local_unit_status(unit) do
    case Executor.unit_status(unit) do
      {:ok, status} -> status
      {:error, _reason} -> :unknown
    end
  end

  defp read_unit_logs(unit, lines) do
    case Executor.unit_logs(unit, lines) do
      {:ok, output} -> ClusterLogs.terminal_safe(output)
      {:error, reason} -> reason |> inspect() |> ClusterLogs.terminal_safe()
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

  defp deploy_configurations do
    NixSwarm.Config.current().nodes
    |> Enum.reduce(%{}, fn {_node, attrs}, acc ->
      case {Map.get(attrs, :deploy_host), Map.get(attrs, :nixos_configuration)} do
        {host, configuration} when is_binary(host) and is_binary(configuration) ->
          Map.put(acc, host, configuration)

        _ ->
          acc
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
