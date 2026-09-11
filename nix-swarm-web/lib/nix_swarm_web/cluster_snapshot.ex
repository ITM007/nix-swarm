defmodule NixSwarmWeb.ClusterSnapshot do
  @moduledoc """
  Presentation-neutral, stable projection of the agent's cluster overview.

  This module deliberately accepts both the JSON representation (string keys and
  tuple arrays) and the native API representation (atom keys and tuples). No
  external identifier is converted to an atom.
  """

  @type snapshot :: %{
          captured_at: DateTime.t(),
          queried_node: binary(),
          stale?: boolean(),
          nodes: [map()],
          services: [map()],
          drift: map(),
          graph: map(),
          metrics: map(),
          errors: [map()]
        }

  @doc "Normalizes an agent response into the stable web projection."
  @spec normalize(map(), keyword()) :: snapshot()
  def normalize(payload, opts \\ [])

  def normalize(payload, opts) when is_map(payload) do
    captured_at = Keyword.get(opts, :captured_at, DateTime.utc_now())
    overview = map_value(payload, :overview, payload) |> map_or_empty()
    members = map_value(overview, :members, %{}) |> map_or_empty()
    status = map_value(overview, :status, %{}) |> map_or_empty()

    queried_node =
      status
      |> map_value(
        :queried_node,
        map_value(
          members,
          :queried_node,
          map_value(overview, :queried_node, map_value(payload, :queried_node, "unknown"))
        )
      )
      |> node_name()

    raw_nodes = map_value(status, :nodes, [])
    configured_nodes = list_value(map_value(members, :configured_nodes, []))
    nodes = normalize_nodes(raw_nodes, configured_nodes)
    placements = normalize_placements(map_value(status, :placements, %{}))
    services = normalize_services(nodes, placements, status)
    drift = normalize_drift(status)
    errors = normalize_errors(map_value(payload, :errors, []), nodes)
    metrics = normalize_metrics(nodes, services)

    %{
      captured_at: captured_at,
      captured_at_ms: DateTime.to_unix(captured_at, :millisecond),
      queried_node: queried_node,
      stale?: Keyword.get(opts, :stale?, false),
      nodes: nodes,
      services: services,
      drift: drift,
      graph: graph(nodes, services),
      metrics: metrics,
      summary: summary(nodes, services, members, status),
      errors: errors
    }
  end

  def normalize(_payload, opts), do: empty(Keyword.get(opts, :captured_at, DateTime.utc_now()))

  @doc "Returns a stable empty projection used before the first successful poll."
  @spec empty(DateTime.t(), keyword()) :: snapshot()
  def empty(captured_at \\ DateTime.utc_now(), opts \\ []) do
    %{
      captured_at: captured_at,
      captured_at_ms: DateTime.to_unix(captured_at, :millisecond),
      queried_node: "unknown",
      stale?: Keyword.get(opts, :stale?, false),
      nodes: [],
      services: [],
      drift: %{config_consistent?: nil, digests: %{}, diagnostics: [], versions: %{}},
      graph: %{nodes: [], ownership_edges: []},
      metrics: %{cluster: unknown_metrics(), nodes: %{}, services: %{}},
      summary: %{
        configured_nodes: 0,
        live_nodes: 0,
        placement_nodes: 0,
        services: 0,
        running_services: 0,
        degraded_services: 0,
        awaiting_heal_services: 0
      },
      errors: []
    }
  end

  @doc "Stable identity for a service slot, shared by rendering and rate computation."
  def slot_key(service_name, slot) when is_binary(service_name) and is_map(slot) do
    slot_number =
      case Map.get(slot, :slot) do
        nil -> "unknown"
        value -> to_string(value)
      end

    unit = Map.get(slot, :unit, "unknown") |> to_string()
    "#{service_name}|#{slot_number}|#{unit}"
  end

  defp normalize_nodes(raw_nodes, configured_nodes) do
    observed_entries = node_entries(raw_nodes)

    observed_names =
      MapSet.new(observed_entries, fn {name, attrs} ->
        attrs = map_or_empty(attrs)
        node_name(map_value(attrs, :node, name))
      end)

    missing_entries =
      configured_nodes
      |> Enum.map(&node_name/1)
      |> Enum.reject(&(&1 == "unknown"))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(observed_names, &1))
      |> Enum.map(&{&1, unavailable_node_attrs()})

    (missing_entries ++ observed_entries)
    |> Enum.map(fn {name, attrs} -> normalize_node(name, attrs) end)
    |> Enum.sort_by(& &1.name)
  end

  defp unavailable_node_attrs do
    %{availability: "unavailable", error: "node_unreachable", reason: "not_live"}
  end

  defp node_entries(nodes) when is_map(nodes), do: Map.to_list(nodes)

  defp node_entries(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, fn
      {name, attrs} when is_map(attrs) ->
        [{name, attrs}]

      [name, attrs] when is_map(attrs) ->
        [{name, attrs}]

      attrs when is_map(attrs) ->
        case map_value(attrs, :node, nil) do
          nil -> []
          name -> [{name, attrs}]
        end

      _ ->
        []
    end)
  end

  defp node_entries(_), do: []

  defp normalize_node(name, attrs) do
    attrs = map_or_empty(attrs)
    name = node_name(map_value(attrs, :node, name))
    error = map_value(attrs, :error, nil) |> null_to_nil()

    %{
      name: name,
      host: host_name(name, map_value(attrs, :host, nil)),
      status: node_status(attrs, error),
      availability: string_value(map_value(attrs, :availability, "unknown")),
      version:
        string_value(map_value(attrs, :version, map_value(attrs, :release_version, "unknown"))),
      build_version: string_value(map_value(attrs, :build_version, "unknown")),
      release_version: string_value(map_value(attrs, :release_version, "unknown")),
      config_digest: string_value(map_value(attrs, :config_digest, "unknown")),
      services: normalize_node_services(map_value(attrs, :services, [])),
      metrics: normalize_node_metrics(map_value(attrs, :metrics, %{})),
      network_info: normalize_network_info(map_value(attrs, :network_info, %{})),
      proxy: normalize_proxy(map_value(attrs, :proxy, %{})),
      error: normalize_error(error, attrs)
    }
  end

  defp node_status(attrs, error) do
    explicit_status = attrs |> map_value(:status, nil) |> null_to_nil()
    operational_state = attrs |> map_value(:operational_state, nil) |> null_to_nil()
    availability = attrs |> map_value(:availability, nil) |> null_to_nil()

    cond do
      not is_nil(error) ->
        "down"

      explicit_status not in [nil, ""] ->
        string_value(map_value(attrs, :status, "unknown"))

      operational_state not in [nil, ""] ->
        operational_state
        |> map_or_empty()
        |> map_value(:status, "unknown")
        |> string_value()

      availability in ["active", :active] ->
        "up"

      availability in ["draining", :draining] ->
        "degraded"

      true ->
        "unknown"
    end
  end

  defp normalize_node_services(services) when is_list(services) do
    services
    |> Enum.flat_map(fn service ->
      service = map_or_empty(service)
      name = map_value(service, :name, nil) |> null_to_nil()
      if is_nil(name), do: [], else: [{string_value(name), service}]
    end)
    |> Map.new(fn {name, service} ->
      {name,
       %{
         name: name,
         desired_state: string_value(map_value(service, :desired_state, "unknown")),
         local_owned_slots: list_value(map_value(service, :local_owned_slots, [])),
         units: normalize_units(map_value(service, :units, []))
       }}
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  defp normalize_node_services(_), do: []

  defp normalize_units(units) when is_list(units) do
    units
    |> Enum.map(&map_or_empty/1)
    |> Enum.map(fn unit ->
      unit_name = string_value(map_value(unit, :unit, "unknown"))

      %{
        unit: unit_name,
        slot: slot_number(unit_name, map_value(unit, :slot, nil)),
        status: string_value(map_value(unit, :status, "unknown")),
        owner: optional_node(map_value(unit, :owner, nil)),
        ports: normalize_ports(map_value(unit, :ports, map_value(unit, :port, []))),
        metrics: normalize_unit_metrics(map_value(unit, :metrics, %{}))
      }
    end)
    |> Enum.sort_by(fn unit -> {unit.slot || 1_000_000, unit.unit} end)
  end

  defp normalize_units(_), do: []

  defp normalize_unit_metrics(metrics) do
    metrics
    |> map_or_empty()
    |> Enum.map(fn {key, value} ->
      value = if is_map(value), do: normalize_metric(value), else: number_or_string(value)
      {metric_key(key), value}
    end)
    |> Map.new()
  end

  defp normalize_placements(placements) when is_map(placements) do
    placements
    |> Enum.map(fn {service, slots} ->
      {string_value(service), normalize_placement_slots(slots)}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp normalize_placements(_), do: %{}

  defp normalize_placement_slots(slots) when is_list(slots) do
    slots
    |> Enum.map(&map_or_empty/1)
    |> Enum.with_index()
    |> Enum.map(fn {slot, index} ->
      slot_number =
        case map_value(slot, :slot, nil) |> null_to_nil() do
          value when is_integer(value) -> value
          value when is_binary(value) -> parse_integer(value, index)
          _ -> index
        end

      %{
        slot: slot_number,
        owner: optional_node(map_value(slot, :owner, nil)),
        unit: string_value(map_value(slot, :unit, "unknown")),
        status: string_value(map_value(slot, :status, "unknown")),
        ports: normalize_ports(map_value(slot, :ports, map_value(slot, :port, [])))
      }
    end)
    |> Enum.sort_by(& &1.slot)
  end

  defp normalize_placement_slots(_), do: []

  defp normalize_services(nodes, placements, status) do
    names =
      (Map.keys(placements) ++
         Enum.flat_map(nodes, fn node -> Enum.map(node.services, & &1.name) end) ++
         map_value(status, :services, []))
      |> service_names()
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(names, fn name ->
      placement_slots = Map.get(placements, name, [])

      unit_records =
        nodes
        |> Enum.flat_map(fn node ->
          node.services
          |> Enum.filter(&(&1.name == name))
          |> Enum.flat_map(fn service ->
            Enum.map(service.units, &Map.put(&1, :node, node.name))
          end)
        end)

      slots = merge_slots(placement_slots, unit_records)
      desired_replicas = desired_replicas(status, name, slots)
      awaiting_heal? = Enum.any?(unit_records, &awaiting_heal?(&1.status))
      unplaced_slots = Enum.count(slots, &is_nil(&1.owner))
      running_slots = Enum.count(slots, &(&1.status == "running" and not is_nil(&1.owner)))
      degraded? = awaiting_heal? or unplaced_slots > 0 or Enum.any?(slots, &bad_slot?/1)

      %{
        name: name,
        desired_replicas: desired_replicas,
        slots: slots,
        running_slots: running_slots,
        status:
          if(degraded?,
            do: "degraded",
            else: if(running_slots > 0, do: "running", else: "unknown")
          ),
        degraded?: degraded?,
        awaiting_heal?: awaiting_heal?,
        unplaced_slots: unplaced_slots,
        state_contract: map_value(map_value(status, :state_contracts, %{}), name, nil)
      }
    end)
  end

  defp service_names(services) when is_list(services), do: Enum.map(services, &string_value/1)

  defp service_names(services) when is_map(services),
    do: Map.keys(services) |> Enum.map(&string_value/1)

  defp service_names(_), do: []

  defp merge_slots(placement_slots, unit_records) do
    placement_slots
    |> Enum.map(fn placement ->
      candidates = Enum.filter(unit_records, &same_slot?(&1, placement))
      unit = select_unit(candidates, placement.owner)

      placement
      |> Map.put(:status, slot_status(placement, unit))
      |> Map.put(:ports, slot_ports(placement, unit))
      |> Map.put(:metrics, if(unit, do: unit.metrics, else: %{}))
    end)
    |> add_unplaced_units(unit_records)
    |> Enum.uniq_by(fn slot -> {slot.slot, slot.unit} end)
    |> Enum.sort_by(fn slot -> {slot.slot || 1_000_000, slot.unit} end)
  end

  defp add_unplaced_units(slots, unit_records) do
    known = MapSet.new(slots, fn slot -> {slot.slot, slot.unit} end)

    Enum.reduce(unit_records, slots, fn unit, acc ->
      if MapSet.member?(known, {unit.slot, unit.unit}) do
        acc
      else
        [
          %{
            slot: unit.slot || length(acc),
            owner: unit.owner,
            unit: unit.unit,
            status: unit.status,
            ports: unit.ports,
            metrics: unit.metrics
          }
          | acc
        ]
      end
    end)
  end

  defp same_slot?(unit, placement) do
    unit.unit == placement.unit or
      (not is_nil(unit.slot) and unit.slot == placement.slot)
  end

  defp select_unit([], _owner), do: nil

  defp select_unit(units, owner) do
    Enum.find(units, List.first(units), &(&1.node == owner or &1.owner == owner))
  end

  defp slot_status(placement, nil) do
    if is_nil(placement.owner), do: "unplaced", else: placement.status
  end

  defp slot_status(_placement, unit), do: unit.status

  defp slot_ports(placement, nil), do: placement.ports

  defp slot_ports(placement, unit) do
    if unit.ports == [], do: placement.ports, else: unit.ports
  end

  defp desired_replicas(status, name, slots) do
    desired =
      status
      |> map_value(:desired_observed, %{})
      |> map_value(:desired, %{})
      |> map_value(:services, %{})
      |> map_value(name, %{})
      |> map_value(:desired_replicas, nil)
      |> null_to_nil()

    cond do
      is_integer(desired) and desired >= 0 -> desired
      slots == [] -> 0
      true -> (Enum.map(slots, &(&1.slot || -1)) |> Enum.max()) + 1
    end
  end

  defp normalize_drift(status) do
    digests =
      status
      |> map_value(:config_digests, %{})
      |> map_or_empty()
      |> Map.new(fn {node, digest} -> {node_name(node), string_value(digest)} end)

    config_consistent =
      case map_value(status, :config_consistent?, :missing) do
        value when value in [true, false] -> value
        _ -> infer_consistency(digests)
      end

    diagnostics = list_value(map_value(status, :placement_diagnostics, [])) |> normalize_maps()
    desired_observed = map_value(status, :desired_observed, %{}) |> map_or_empty()

    diagnostics =
      (diagnostics ++ list_value(map_value(desired_observed, :drift, []))) |> normalize_maps()

    versions =
      status
      |> map_value(:nodes, [])
      |> node_entries()
      |> Enum.group_by(
        fn {_name, attrs} ->
          attrs
          |> map_or_empty()
          |> map_value(:release_version, map_value(attrs, :version, "unknown"))
          |> string_value()
        end,
        fn {name, _attrs} -> node_name(name) end
      )
      |> Map.new(fn {version, names} -> {version, Enum.sort(names)} end)

    %{
      config_consistent?: config_consistent,
      digests: digests,
      diagnostics: diagnostics,
      versions: versions,
      desired_observed: desired_observed
    }
  end

  defp infer_consistency(digests) do
    values = Map.values(digests)
    known = Enum.reject(values, &(&1 in ["unknown", ""]))

    cond do
      values == [] -> nil
      length(known) != length(values) -> false
      true -> known |> Enum.uniq() |> length() == 1
    end
  end

  defp normalize_metrics(nodes, services) do
    node_metrics = Map.new(nodes, &{&1.name, &1.metrics})
    cluster = aggregate_metrics(Enum.map(nodes, & &1.metrics))

    service_metrics =
      services
      |> Map.new(fn service ->
        metrics =
          service.slots
          |> Enum.map(&Map.get(&1, :metrics, %{}))
          |> aggregate_service_metrics()

        {service.name, metrics}
      end)

    %{cluster: cluster, nodes: node_metrics, services: service_metrics}
  end

  defp aggregate_metrics(metrics) do
    fields = [:cpu, :memory, :disk]

    aggregate =
      Map.new(fields, fn field ->
        values = Enum.map(metrics, &Map.get(&1, field, %{}))
        used = Enum.reduce(values, 0, &(number_value(Map.get(&1, :used, 0)) + &2))
        total = Enum.reduce(values, 0, &(number_value(Map.get(&1, :total, 0)) + &2))
        pct = percentage(used, total, values)

        {field,
         if(values == [], do: %{status: "unknown"}, else: %{used: used, total: total, pct: pct})}
      end)

    network_values = Enum.map(metrics, &Map.get(&1, :network, %{}))

    network =
      if network_values == [] do
        %{status: "unknown"}
      else
        %{
          received:
            Enum.reduce(network_values, 0, &(number_value(Map.get(&1, :received, 0)) + &2)),
          transmitted:
            Enum.reduce(network_values, 0, &(number_value(Map.get(&1, :transmitted, 0)) + &2)),
          total: Enum.reduce(network_values, 0, &(number_value(Map.get(&1, :total, 0)) + &2))
        }
      end

    Map.put(aggregate, :network, network)
  end

  defp aggregate_service_metrics(metrics) do
    Enum.reduce(metrics, %{}, fn metric, acc ->
      Enum.reduce(metric, acc, fn {key, value}, result ->
        key = metric_key(key)
        value = if is_map(value), do: value, else: value
        Map.update(result, key, value, &sum_metric(&1, value))
      end)
    end)
  end

  defp sum_metric(left, right) when is_number(left) and is_number(right), do: left + right
  defp sum_metric(_left, right), do: right

  defp normalize_node_metrics(metrics) do
    metrics = map_or_empty(metrics)

    %{
      cpu: normalize_metric(map_value(metrics, :cpu, %{})),
      memory: normalize_metric(map_value(metrics, :memory, %{})),
      disk: normalize_metric(map_value(metrics, :disk, %{})),
      network: normalize_metric(map_value(metrics, :network, %{})),
      uptime: number_value(map_value(metrics, :uptime, 0))
    }
  end

  defp normalize_metric(metric) when is_map(metric) do
    metric
    |> Enum.map(fn {key, value} -> {metric_key(key), number_or_string(value)} end)
    |> Map.new()
  end

  defp normalize_metric(value) when is_number(value), do: value
  defp normalize_metric(_), do: %{}

  defp metric_key("used"), do: :used
  defp metric_key("total"), do: :total
  defp metric_key("pct"), do: :pct
  defp metric_key("cpu"), do: :cpu
  defp metric_key("memory"), do: :memory
  defp metric_key("disk"), do: :disk
  defp metric_key("network"), do: :network
  defp metric_key("received"), do: :received
  defp metric_key("transmitted"), do: :transmitted
  defp metric_key("usage_ns"), do: :usage_ns
  defp metric_key(key) when is_atom(key), do: key
  defp metric_key(key), do: key

  defp normalize_network_info(info) do
    info = map_or_empty(info)

    %{
      ips: list_value(map_value(info, :ips, [])) |> Enum.map(&string_value/1),
      ports: list_value(map_value(info, :ports, []))
    }
  end

  defp normalize_proxy(proxy) do
    proxy = map_or_empty(proxy)

    %{
      enabled?: map_value(proxy, :enabled?, map_value(proxy, :enabled, false)) in [true, "true"],
      listen_port: normalize_port(map_value(proxy, :listen_port, nil)),
      routes:
        proxy
        |> map_value(:routes, [])
        |> proxy_route_list()
        |> Enum.map(&normalize_proxy_route/1),
      metrics: normalize_unit_metrics(map_value(proxy, :metrics, %{}))
    }
  end

  defp proxy_route_list(routes) when is_map(routes), do: Map.values(routes)
  defp proxy_route_list(routes) when is_list(routes), do: routes
  defp proxy_route_list(_routes), do: []

  defp normalize_proxy_route(route) do
    route = map_or_empty(route)

    %{
      name: string_value(map_value(route, :name, "unknown")),
      host: string_value(map_value(route, :host, "unknown")),
      path_prefix: string_value(map_value(route, :path_prefix, "/")),
      upstreams: list_value(map_value(route, :upstreams, [])) |> Enum.map(&string_value/1),
      auth: string_value(map_value(route, :auth, "public"))
    }
  end

  defp normalize_port(value) when is_integer(value) and value in 1..65_535, do: value
  defp normalize_port(value) when is_binary(value), do: parse_integer(value, nil)
  defp normalize_port(_value), do: nil

  defp normalize_ports(value) when is_list(value) do
    value
    |> Enum.map(fn
      port when is_integer(port) -> port
      port when is_binary(port) -> parse_integer(port, nil)
      _ -> nil
    end)
    |> Enum.filter(&is_integer/1)
    |> Enum.filter(&(&1 in 1..65_535))
    |> Enum.uniq()
  end

  defp normalize_ports(value), do: normalize_ports([value])

  defp graph(nodes, services) do
    graph_nodes = Enum.map(nodes, &Map.take(&1, [:name, :host, :status, :version]))

    ownership_edges =
      services
      |> Enum.flat_map(fn service ->
        Enum.map(service.slots, fn slot ->
          %{service: service.name, slot: slot.slot, unit: slot.unit, owner: slot.owner}
        end)
      end)
      |> Enum.sort_by(fn edge -> {edge.service, edge.slot || 1_000_000, edge.unit} end)

    %{nodes: graph_nodes, ownership_edges: ownership_edges}
  end

  defp summary(nodes, services, members, status) do
    configured = list_value(map_value(members, :configured_nodes, []))
    live = list_value(map_value(members, :live_nodes, map_value(status, :live_nodes, [])))

    placement =
      list_value(map_value(members, :placement_nodes, map_value(status, :placement_nodes, [])))

    %{
      configured_nodes: max(length(configured), length(nodes)),
      live_nodes: length(live),
      placement_nodes: length(placement),
      services: length(services),
      running_services: Enum.count(services, &(&1.running_slots > 0)),
      degraded_services: Enum.count(services, & &1.degraded?),
      awaiting_heal_services: Enum.count(services, & &1.awaiting_heal?)
    }
  end

  defp normalize_errors(errors, nodes) do
    explicit = errors |> list_value() |> normalize_maps()

    node_errors =
      nodes
      |> Enum.filter(&Map.get(&1, :error))
      |> Enum.map(fn node ->
        %{
          scope: "node",
          node: node.name,
          reason: Map.get(node.error, :reason, "node_unreachable")
        }
      end)

    (explicit ++ node_errors)
    |> Enum.uniq()
  end

  defp normalize_error(nil, _attrs), do: nil

  defp normalize_error(error, attrs) do
    %{reason: string_value(map_value(attrs, :reason, error)), error: string_value(error)}
  end

  defp normalize_maps(values) do
    Enum.map(values, fn value ->
      value
      |> map_or_empty()
      |> Enum.map(fn {key, item} -> {stable_key(key), normalize_error_value(item)} end)
      |> Map.new()
    end)
  end

  defp stable_key(key)
       when key in [
              :reason,
              :service,
              :node,
              :severity,
              :slot,
              :scope,
              :field,
              :desired,
              :observed
            ],
       do: key

  defp stable_key("reason"), do: :reason
  defp stable_key("service"), do: :service
  defp stable_key("node"), do: :node
  defp stable_key("severity"), do: :severity
  defp stable_key("slot"), do: :slot
  defp stable_key("scope"), do: :scope
  defp stable_key("field"), do: :field
  defp stable_key("desired"), do: :desired
  defp stable_key("observed"), do: :observed
  defp stable_key(key), do: key

  defp normalize_error_value(value)
       when is_atom(value) and value not in [true, false, nil, :null], do: Atom.to_string(value)

  defp normalize_error_value(value), do: null_to_nil(value)

  defp map_value(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_value(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key, default)
  end

  defp map_value(_, _key, default), do: default

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_), do: %{}

  defp list_value(value) when is_list(value), do: value
  defp list_value(_), do: []

  defp node_name(value) do
    case null_to_nil(value) do
      nil -> "unknown"
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end
  end

  defp optional_node(value) do
    case null_to_nil(value) do
      nil -> nil
      value -> node_name(value)
    end
  end

  defp host_name(name, host) do
    case null_to_nil(host) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        case String.split(name, "@", parts: 2) do
          [_node, host] when host != "" -> host
          _ -> "unknown"
        end
    end
  end

  defp string_value(value) do
    case null_to_nil(value) do
      nil -> "unknown"
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end
  end

  defp number_or_string(value) when is_number(value), do: value
  defp number_or_string(value), do: string_value(value)

  defp number_value(value) when is_number(value), do: value
  defp number_value(_), do: 0

  defp percentage(used, total, values) do
    cond do
      total > 0 ->
        Float.round(used / total * 100, 2)

      Enum.any?(values, &is_map/1) ->
        pcts = Enum.map(values, &Map.get(&1, :pct, 0)) |> Enum.filter(&is_number/1)
        if pcts == [], do: 0, else: Float.round(Enum.sum(pcts) / length(pcts), 2)

      true ->
        0
    end
  end

  defp unknown_metrics do
    %{
      cpu: %{status: "unknown"},
      memory: %{status: "unknown"},
      disk: %{status: "unknown"},
      network: %{status: "unknown"}
    }
  end

  defp slot_number(unit, fallback) do
    case null_to_nil(fallback) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        parse_integer(value, nil)

      _ ->
        case Regex.run(~r/@(\d+)(?:\.|$)/, unit) do
          [_, number] -> String.to_integer(number)
          _ -> nil
        end
    end
  end

  defp parse_integer(value, fallback) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> fallback
    end
  end

  defp awaiting_heal?(status), do: status in ["awaiting_heal", "awaiting-heal", "awaiting heal"]
  defp bad_slot?(slot), do: slot.status not in ["running", "unknown"]

  defp null_to_nil(value) when value in [nil, :null, "null"], do: nil
  defp null_to_nil(value), do: value
end
