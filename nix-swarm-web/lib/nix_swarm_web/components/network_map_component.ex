defmodule NixSwarmWeb.NetworkMapComponent do
  @moduledoc "Interactive, keyboard-readable SVG projection of cluster ownership."

  use Phoenix.Component

  alias NixSwarmWeb.{ClusterSnapshot, Format}

  attr(:snapshot, :map, required: true)
  attr(:service_ports, :map, default: %{})

  @width 1_200
  @minimum_height 720
  @margin_x 80
  @top 120
  @machine_width 820
  @machine_padding 24
  @machine_gap 48
  @machine_header_height 172
  @service_cols 2
  @service_gap 16
  @service_height 140
  @proxy_width 520
  @proxy_height 144
  @proxy_x @margin_x
  @proxy_y 24
  @service_width div(@machine_width - 2 * @machine_padding - @service_gap, @service_cols)
  @unplaced_header_height 64
  @bottom_padding 80

  @doc "Renders a network canvas where each machine is a rectangle containing its services."
  def network_map(assigns) do
    snapshot = Map.get(assigns, :snapshot, %{})
    nodes = snapshot |> Map.get(:nodes, []) |> Enum.sort_by(&Map.get(&1, :name, ""))

    service_cpu = get_in(snapshot, [:metrics, :rates, :service_cpu]) || %{}
    service_network = get_in(snapshot, [:metrics, :rates, :service_network]) || %{}
    node_network = get_in(snapshot, [:metrics, :rates, :node_network]) || %{}
    proxy_network = get_in(snapshot, [:metrics, :rates, :proxy_network]) || %{}
    configured_ports = Map.get(assigns, :service_ports, %{})

    nodes = Enum.map(nodes, &Map.put(&1, :network_rate, Map.get(node_network, &1.name)))

    slots =
      snapshot
      |> Map.get(:services, [])
      |> Enum.sort_by(&Map.get(&1, :name, ""))
      |> Enum.flat_map(fn service ->
        name = Map.get(service, :name, "unknown")

        service
        |> Map.get(:slots, [])
        |> Enum.map(fn slot ->
          slot
          |> Map.put(:service, name)
          |> Map.put(:cpu_pct, Map.get(service_cpu, ClusterSnapshot.slot_key(name, slot), nil))
          |> Map.put(
            :network_rate,
            Map.get(service_network, ClusterSnapshot.slot_key(name, slot))
          )
          |> Map.put(:config_ports, Map.get(configured_ports, name, []))
        end)
      end)
      |> Enum.sort_by(fn slot ->
        {slot_service(slot), Map.get(slot, :slot) || 1_000_000, Map.get(slot, :unit, "")}
      end)

    owned_slots = Enum.filter(slots, &Map.get(&1, :owner))
    unplaced_slots = Enum.reject(slots, &Map.get(&1, :owner))

    machines =
      Enum.map(nodes, fn node ->
        name = Map.get(node, :name, "unknown")
        {node, Enum.filter(owned_slots, &(&1.owner == name))}
      end)

    proxy = proxy_projection(nodes, proxy_network)
    flow_edges = proxy_flow_edges(proxy, nodes)
    flow_rows = traffic_flow_rows(nodes, slots, proxy, flow_edges)

    machine_columns = machine_column_count(length(machines))
    machine_rows = Enum.chunk_every(machines, machine_columns)

    machine_top = if proxy.enabled?, do: @top + @proxy_height + @machine_gap, else: @top

    {machine_layout, next_y} =
      machine_rows
      |> Enum.reduce({%{}, machine_top}, fn row, {layout, y} ->
        row_height =
          row
          |> Enum.map(fn {_node, node_slots} -> machine_height(length(node_slots)) end)
          |> Enum.max()

        layout =
          row
          |> Enum.with_index()
          |> Enum.reduce(layout, fn {{node, node_slots}, column}, row_layout ->
            name = Map.get(node, :name, "unknown")
            height = machine_height(length(node_slots))
            x = @margin_x + column * (@machine_width + @machine_gap)
            Map.put(row_layout, name, %{x: x, y: y, height: height})
          end)

        {layout, y + row_height + @machine_gap}
      end)

    unplaced_y = next_y
    unplaced_height = if unplaced_slots == [], do: 0, else: machine_height(length(unplaced_slots))

    width =
      max(
        @width,
        @margin_x * 2 + machine_columns * @machine_width + (machine_columns - 1) * @machine_gap
      )

    height = max(unplaced_y + unplaced_height + @bottom_padding, @minimum_height)

    service_positions =
      machines
      |> Enum.reduce(%{}, fn {_node, node_slots}, acc ->
        node_slots
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {slot, index}, inner ->
          row = div(index, @service_cols)
          col = rem(index, @service_cols)

          Map.put(
            inner,
            ClusterSnapshot.slot_key(slot_service(slot), slot),
            %{
              x: @machine_padding + col * (@service_width + @service_gap),
              y:
                @machine_header_height + @machine_padding + row * (@service_height + @service_gap)
            }
          )
        end)
      end)

    unplaced_positions =
      unplaced_slots
      |> Enum.with_index()
      |> Map.new(fn {slot, index} ->
        row = div(index, @service_cols)
        col = rem(index, @service_cols)

        {ClusterSnapshot.slot_key(slot_service(slot), slot),
         %{
           x: @margin_x + @machine_padding + col * (@service_width + @service_gap),
           y:
             unplaced_y + @unplaced_header_height + @machine_padding +
               row * (@service_height + @service_gap)
         }}
      end)

    assigns =
      assigns
      |> assign(:snapshot, snapshot)
      |> assign(:service_ports, configured_ports)
      |> assign(:nodes, nodes)
      |> assign(:machines, machines)
      |> assign(:machine_layout, machine_layout)
      |> assign(:service_positions, service_positions)
      |> assign(:unplaced_slots, unplaced_slots)
      |> assign(:unplaced_positions, unplaced_positions)
      |> assign(:unplaced_y, unplaced_y)
      |> assign(:unplaced_height, unplaced_height)
      |> assign(:proxy, proxy)
      |> assign(:flow_edges, flow_edges)
      |> assign(:flow_rows, flow_rows)
      |> assign(:width, width)
      |> assign(:height, height)
      |> assign(:machine_width, @machine_width)
      |> assign(:machine_header_height, @machine_header_height)
      |> assign(:proxy_width, @proxy_width)
      |> assign(:proxy_height, @proxy_height)
      |> assign(:machine_padding, @machine_padding)
      |> assign(:margin_x, @margin_x)
      |> assign(:service_width, @service_width)
      |> assign(:service_height, @service_height)

    ~H"""
    <section class="network-map" aria-label="Cluster map">
      <h2 class="visually-hidden">Cluster map</h2>
      <div
        id="cluster-map"
        class="map-workspace"
        phx-hook="NetworkMap"
        data-map-width={@width}
        data-map-height={@height}
      >
        <div class="map-toolbar" role="toolbar" aria-label="Map controls">
          <div class="map-toolbar__group">
            <button type="button" class="btn btn-sm btn-ghost" data-map-action="zoom-out" aria-label="Zoom out">−</button>
            <span class="map-zoom" data-map-zoom aria-live="polite">100%</span>
            <button type="button" class="btn btn-sm btn-ghost" data-map-action="zoom-in" aria-label="Zoom in">+</button>
          </div>
          <div class="map-toolbar__group">
            <button type="button" class="btn btn-sm btn-outline" data-map-action="fit">Fit map</button>
            <button type="button" class="btn btn-sm btn-ghost" data-map-action="reset">Reset layout</button>
          </div>
          <span class="map-toolbar__hint">Pan · zoom · arrange</span>
        </div>

        <div class="map-layout">
          <div class="map-canvas" data-map-canvas>
            <svg
              role="img"
              aria-label="Interactive cluster machines and their services"
              viewBox={"0 0 #{@width} #{@height}"}
              data-map-svg
            >
              <title>Interactive cluster machines and their services</title>
              <desc>Move around the topology, select a machine or service, and inspect its current status.</desc>
              <defs>
                <marker id="map-flow-arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                  <path d="M 0 0 L 10 5 L 0 10 z" />
                </marker>
              </defs>
              <rect width={@width} height={@height} class="map-backdrop" data-map-background />
              <g data-map-viewport>
                <g data-map-flows aria-label="Declared proxy routes">
                  <%= for flow <- @flow_edges do %>
                    <path
                      class="map-flow-edge map-flow-edge--declared"
                      data-map-flow
                      data-map-flow-source="proxy"
                      data-map-flow-target={flow.target}
                      data-map-flow-label={flow.label}
                      d={flow_path(flow, @proxy, @machine_layout)}
                      marker-end="url(#map-flow-arrow)"
                    />
                  <% end %>
                </g>
                <g data-map-items>
                  <%= if @proxy.enabled? do %>
                    <g
                      class="map-item map-proxy is-live"
                      data-map-item-key="proxy"
                      data-map-item-kind="proxy"
                      data-map-title="Nix-Swarm proxy"
                      data-map-status="Enabled"
                      data-map-subtitle={proxy_subtitle(@proxy)}
                      data-map-detail={proxy_detail(@proxy)}
                      data-map-x={@proxy.x}
                      data-map-y={@proxy.y}
                      data-map-box-width={@proxy_width}
                      data-map-box-height={@proxy_height}
                      transform={"translate(#{@proxy.x} #{@proxy.y})"}
                      role="button"
                      tabindex="0"
                      aria-label={proxy_detail(@proxy)}
                    >
                      <rect class="map-card map-proxy-card" width={@proxy_width} height={@proxy_height} rx="12" />
                      <circle class="map-status-dot" cx="28" cy="30" r="7" />
                      <text x="48" y="36" class="map-card-title">Nix-Swarm proxy</text>
                      <text x="28" y="68" class="map-card-subtitle"><%= truncate(proxy_subtitle(@proxy), 64) %></text>
                      <text x="28" y="96" class="map-card-detail"><%= truncate(proxy_traffic_label(@proxy), 64) %></text>
                      <text x="28" y="124" class="map-card-detail map-card-detail--secondary"><%= truncate("#{length(@flow_edges)} declared route connections", 64) %></text>
                      <title><%= proxy_detail(@proxy) %></title>
                    </g>
                  <% end %>
                  <%= for {node, node_slots} <- @machines do %>
                    <% name = Map.get(node, :name, "unknown") %>
                    <% layout = Map.fetch!(@machine_layout, name) %>
                    <% machine_ip = node_ip(node) %>
                    <g
                      class={"map-item map-node #{node_class(node)}"}
                      data-map-item-key={name}
                      data-map-item-kind="node"
                      data-map-title={name}
                      data-map-status={status_label(Map.get(node, :status))}
                      data-map-subtitle={node_network_label(node)}
                      data-map-detail={node_detail(node)}
                      data-map-x={layout.x}
                      data-map-y={layout.y}
                      data-map-box-width={@machine_width}
                      data-map-box-height={layout.height}
                      role="button"
                      tabindex="0"
                      aria-label={node_label(node)}
                    >
                      <rect class="map-card map-machine" width={@machine_width} height={layout.height} rx="12" data-map-drag />
                      <circle class="map-status-dot" cx="28" cy="30" r="7" />
                      <text x="48" y="36" class="map-card-title"><%= truncate(name, 42) %></text>
                      <text x="28" y="66" class="map-card-subtitle"><%= truncate("IP #{machine_ip}", 56) %></text>
                      <text x="28" y="90" class="map-card-detail"><%= truncate(node_ports_label(node), 56) %></text>
                      <text x="28" y="116" class="map-card-detail"><%= truncate(node_metrics_label(node), 56) %></text>
                      <text x="28" y="140" class="map-card-detail"><%= truncate(node_traffic_label(node), 56) %></text>
                      <text x="28" y="164" class="map-card-detail map-card-detail--secondary"><%= truncate(node_state_label(node), 56) %></text>
                      <%= if node_slots == [] do %>
                        <text x="28" y={@machine_header_height + @machine_padding + 30} class="map-machine-empty">No owned services</text>
                      <% else %>
                        <%= for slot <- node_slots do %>
                          <% sp = Map.fetch!(@service_positions, ClusterSnapshot.slot_key(slot_service(slot), slot)) %>
                          <g
                            class={"map-item map-service #{slot_class(slot)}"}
                            data-map-item-key={ClusterSnapshot.slot_key(slot_service(slot), slot)}
                            data-map-item-kind="service"
                            data-map-machine={name}
                            data-map-title={slot_service(slot)}
                            data-map-status={status_label(Map.get(slot, :status))}
                            data-map-subtitle={Map.get(slot, :unit, "unknown")}
                            data-map-detail={slot_detail(slot)}
                            role="button"
                            tabindex="0"
                            aria-label={slot_label(slot)}
                          >
                            <rect class="map-card map-service-card" x={sp.x} y={sp.y} width={@service_width} height={@service_height} rx="8" />
                            <circle class="map-status-dot" cx={sp.x + 24} cy={sp.y + 26} r="6" />
                            <text x={sp.x + 42} y={sp.y + 30} class="map-service-title"><%= truncate(slot_service(slot), 24) %></text>
                            <text x={sp.x + 24} y={sp.y + 54} class="map-card-subtitle"><%= truncate("IP #{machine_ip}", 38) %></text>
                            <text x={sp.x + 24} y={sp.y + 82} class="map-card-detail"><%= truncate(slot_metrics_label(slot), 38) %></text>
                            <text x={sp.x + 24} y={sp.y + 106} class="map-card-detail"><%= truncate(slot_traffic_label(slot), 38) %></text>
                            <text x={sp.x + 24} y={sp.y + 130} class="map-card-detail map-card-detail--secondary"><%= truncate(slot_ports_label(slot), 38) %></text>
                            <title><%= slot_label(slot) %></title>
                          </g>
                        <% end %>
                      <% end %>
                      <title><%= node_label(node) %></title>
                    </g>
                  <% end %>

                  <%= if @unplaced_slots != [] do %>
                    <g class="map-unplaced" data-map-unplaced>
                      <rect class="map-card map-unplaced-card" x={@margin_x} y={@unplaced_y} width={@machine_width} height={@unplaced_height} rx="12" />
                      <text x={@margin_x + 28} y={@unplaced_y + 36} class="map-card-title">Unplaced services</text>
                      <%= for slot <- @unplaced_slots do %>
                        <% sp = Map.fetch!(@unplaced_positions, ClusterSnapshot.slot_key(slot_service(slot), slot)) %>
                        <g
                          class={"map-item map-service #{slot_class(slot)}"}
                          data-map-item-key={ClusterSnapshot.slot_key(slot_service(slot), slot)}
                          data-map-item-kind="service"
                          data-map-title={slot_service(slot)}
                          data-map-status={status_label(Map.get(slot, :status))}
                          data-map-subtitle={Map.get(slot, :unit, "unknown")}
                          data-map-detail={slot_detail(slot)}
                          role="button"
                          tabindex="0"
                          aria-label={slot_label(slot)}
                        >
                          <rect class="map-card map-service-card" x={sp.x} y={sp.y} width={@service_width} height={@service_height} rx="8" />
                          <circle class="map-status-dot" cx={sp.x + 24} cy={sp.y + 26} r="6" />
                          <text x={sp.x + 42} y={sp.y + 30} class="map-service-title"><%= truncate(slot_service(slot), 24) %></text>
                          <text x={sp.x + 24} y={sp.y + 54} class="map-card-subtitle"><%= truncate("IP #{owner_ip(slot)}", 38) %></text>
                          <text x={sp.x + 24} y={sp.y + 82} class="map-card-detail"><%= truncate(slot_metrics_label(slot), 38) %></text>
                          <text x={sp.x + 24} y={sp.y + 106} class="map-card-detail"><%= truncate(slot_traffic_label(slot), 38) %></text>
                          <text x={sp.x + 24} y={sp.y + 130} class="map-card-detail map-card-detail--secondary"><%= truncate(slot_ports_label(slot), 38) %></text>
                          <title><%= slot_label(slot) %></title>
                        </g>
                      <% end %>
                    </g>
                  <% end %>
                </g>
              </g>
            </svg>

            <%= if @nodes == [] and @unplaced_slots == [] do %>
              <div class="map-empty" role="status">
                <strong>No cluster items are currently reported.</strong>
                <span>The map will populate after the next successful snapshot.</span>
              </div>
            <% end %>
          </div>

          <aside class="map-inspector is-empty" data-map-inspector aria-live="polite">
            <div data-map-inspector-empty>
              <p class="eyebrow">Inspector</p>
              <h3>Nothing selected</h3>
              <p>Click a node or service to inspect it.</p>
            </div>
            <div data-map-inspector-details hidden>
              <p class="eyebrow" data-inspector-kind>Item</p>
              <h3 data-inspector-title>Selected item</h3>
              <span class="badge" data-inspector-status>Unknown</span>
              <dl class="inspector-facts">
                <div><dt>Details</dt><dd data-inspector-subtitle>Unknown</dd></div>
                <div><dt>Current data</dt><dd data-inspector-detail>Unknown</dd></div>
              </dl>
            </div>
          </aside>
        </div>

        <details class="map-data">
          <summary>Map data table</summary>
          <table class="table table-zebra">
            <caption>Accessible ownership table</caption>
            <thead><tr><th scope="col">Service slot</th><th scope="col">Owner</th><th scope="col">State</th></tr></thead>
            <tbody>
              <%= for slot <- Enum.sort_by(@unplaced_slots ++ Enum.flat_map(@machines, fn {_n, s} -> s end), &{slot_service(&1), Map.get(&1, :slot) || 1_000_000, Map.get(&1, :unit, "")}) do %>
                <tr data-map-table-key={ClusterSnapshot.slot_key(slot_service(slot), slot)}>
                  <th scope="row"><%= Map.get(slot, :unit, "unknown") %></th>
                  <td><%= Map.get(slot, :owner) || "Unplaced" %></td>
                  <td><%= status_label(Map.get(slot, :status)) %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </details>

        <section class="map-flow-panel" data-map-flow-panel aria-label="Network traffic">
          <div class="map-flow-panel__header">
            <div>
              <p class="eyebrow">HUBBLE-LITE</p>
              <h3>Traffic flows</h3>
            </div>
            <span class="badge badge-outline">Layer 4 counters</span>
          </div>
          <p class="map-flow-panel__hint">Observed rates come from host and systemd-unit counters. Proxy links are declared routes, not packet captures.</p>
          <ul class="map-flow-list">
            <%= for flow <- @flow_rows do %>
              <li class={"map-flow-row map-flow-row--#{flow.kind}"}>
                <span class="map-flow-row__kind"><%= flow.label %></span>
                <strong><%= flow.source %> → <%= flow.target %></strong>
                <span><%= flow.detail %></span>
              </li>
            <% end %>
            <%= if @flow_rows == [] do %>
              <li class="map-flow-row map-flow-row--empty">Traffic will appear after two advancing samples.</li>
            <% end %>
          </ul>
        </section>
      </div>
    </section>
    """
  end

  defp proxy_projection(nodes, proxy_network) do
    instances = Enum.filter(nodes, &(get_in(&1, [:proxy, :enabled?]) == true))

    routes =
      instances
      |> Enum.flat_map(fn node ->
        node.proxy.routes
        |> Enum.map(&Map.put(&1, :proxy_node, node.name))
      end)
      |> Enum.uniq_by(&{&1.name, &1.host, &1.path_prefix, &1.upstreams})

    rates =
      instances
      |> Enum.map(&Map.get(proxy_network, &1.name))
      |> Enum.filter(&is_map/1)

    %{
      enabled?: instances != [],
      x: @proxy_x,
      y: @proxy_y,
      routes: routes,
      instances: Enum.map(instances, & &1.name),
      listen_ports:
        instances
        |> Enum.map(&get_in(&1, [:proxy, :listen_port]))
        |> Enum.filter(&is_integer/1)
        |> Enum.uniq()
        |> Enum.sort(),
      rate: aggregate_network_rates(rates)
    }
  end

  defp aggregate_network_rates([]), do: nil

  defp aggregate_network_rates(rates) do
    %{
      received: sum_optional(rates, :received),
      transmitted: sum_optional(rates, :transmitted),
      total: sum_optional(rates, :total),
      rate: sum_optional(rates, :rate)
    }
  end

  defp sum_optional(values, key) do
    numbers = Enum.map(values, &Map.get(&1, key)) |> Enum.filter(&is_number/1)
    if numbers == [], do: nil, else: Enum.sum(numbers)
  end

  defp proxy_flow_edges(%{enabled?: false}, _nodes), do: []

  defp proxy_flow_edges(proxy, nodes) do
    proxy.routes
    |> Enum.flat_map(fn route ->
      Enum.flat_map(route.upstreams, fn upstream ->
        case upstream_target(upstream, nodes) do
          {target, port} ->
            [%{target: target.name, label: "#{route.name} · #{port}", upstream: upstream}]

          nil ->
            []
        end
      end)
    end)
    |> Enum.uniq_by(&{&1.target, &1.label, &1.upstream})
  end

  defp upstream_target(upstream, nodes) when is_binary(upstream) do
    case String.split(upstream, ":", parts: 2) do
      [host, port] ->
        with {port, ""} <- Integer.parse(port),
             node when not is_nil(node) <-
               Enum.find(nodes, &(node_ip(&1) == host or Map.get(&1, :host) == host)) do
          {node, port}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp upstream_target(_upstream, _nodes), do: nil

  defp flow_path(flow, proxy, machine_layout) do
    target = Map.get(machine_layout, flow.target)

    if target do
      source_x = proxy.x + @proxy_width / 2
      source_y = proxy.y + @proxy_height
      target_x = target.x + @machine_width / 2
      target_y = target.y
      bend_y = source_y + max(24, (target_y - source_y) / 2)

      "M #{source_x} #{source_y} C #{source_x} #{bend_y}, #{target_x} #{bend_y}, #{target_x} #{target_y}"
    else
      ""
    end
  end

  defp traffic_flow_rows(nodes, slots, proxy, flow_edges) do
    declared =
      proxy.routes
      |> Enum.flat_map(fn route ->
        Enum.map(route.upstreams, fn upstream ->
          target = Enum.find(flow_edges, &(&1.upstream == upstream))

          %{
            kind: "declared",
            label: "Declared route",
            source: "Proxy",
            target: if(target, do: target.target, else: upstream),
            detail: "#{route.host}#{route.path_prefix} · #{route.auth}"
          }
        end)
      end)

    observed_nodes =
      nodes
      |> Enum.flat_map(fn node ->
        if is_map(node.network_rate) and is_number(node.network_rate.rate) do
          [
            %{
              kind: "observed",
              label: "Observed machine",
              source: node.name,
              target: "network",
              detail: network_rate_label(node.network_rate)
            }
          ]
        else
          []
        end
      end)

    observed_services =
      slots
      |> Enum.flat_map(fn slot ->
        if is_map(Map.get(slot, :network_rate)) and is_number(slot.network_rate.rate) do
          [
            %{
              kind: "observed",
              label: "Observed service",
              source: slot_service(slot),
              target: slot.owner || "unplaced",
              detail: network_rate_label(slot.network_rate)
            }
          ]
        else
          []
        end
      end)

    declared ++ observed_nodes ++ observed_services
  end

  defp machine_height(0) do
    @machine_header_height + 2 * @machine_padding + @service_height
  end

  defp machine_height(count) do
    rows = div(count + @service_cols - 1, @service_cols)

    @machine_header_height + @machine_padding + rows * @service_height + (rows - 1) * @service_gap +
      @machine_padding
  end

  defp machine_column_count(count) when count <= 1, do: 1

  defp machine_column_count(count), do: count |> :math.sqrt() |> Float.ceil() |> trunc()

  defp slot_service(slot), do: Map.get(slot, :service, "unknown")

  defp node_label(node), do: "Node #{Map.get(node, :name, "unknown")}, #{node_detail(node)}"

  defp node_network_label(node) do
    info = Map.get(node, :network_info, %{})
    "IP #{list_label(Map.get(info, :ips, []))} · #{node_ports_label(node)}"
  end

  defp node_ports_label(node) do
    info = Map.get(node, :network_info, %{})
    "Ports #{ports_label(Map.get(info, :ports, []))}"
  end

  defp node_metrics_label(node) do
    metrics = Map.get(node, :metrics, %{})
    "CPU #{cpu_usage(metrics)} · RAM #{memory_usage(metrics)}"
  end

  defp node_traffic_label(node), do: "Traffic #{network_rate_label(Map.get(node, :network_rate))}"

  defp node_state_label(node) do
    "#{status_label(Map.get(node, :status))} · #{Map.get(node, :version, "unknown")}"
  end

  defp node_detail(node) do
    "#{node_network_label(node)} · #{node_metrics_label(node)} · #{node_state_label(node)}"
  end

  # The agent often reports an empty `network_info.ips` list, so the `name@host`
  # portion of the node identity is the reliable IP source for the map.
  defp node_ip(node) do
    case node |> Map.get(:network_info, %{}) |> Map.get(:ips, []) do
      [ip | _] when is_binary(ip) and ip != "" -> ip
      _ -> host_ip(Map.get(node, :name))
    end
  end

  defp owner_ip(slot) do
    case Map.get(slot, :owner) do
      nil -> "unknown"
      owner -> host_ip(owner)
    end
  end

  defp host_ip(name) do
    case String.split(to_string(name || ""), "@", parts: 2) do
      [_node, host] -> if valid_ip?(host), do: host, else: "unknown"
      _ -> "unknown"
    end
  end

  defp valid_ip?(value) when is_binary(value),
    do: match?({:ok, _}, :inet.parse_address(String.to_charlist(value)))

  defp valid_ip?(_value), do: false

  defp slot_metrics_label(slot) do
    "CPU #{slot_cpu_label(slot)} · RAM #{memory_usage(Map.get(slot, :metrics, %{}))}"
  end

  defp slot_traffic_label(slot), do: "Traffic #{network_rate_label(Map.get(slot, :network_rate))}"

  defp proxy_subtitle(proxy) do
    ports = if proxy.listen_ports == [], do: "unknown", else: Enum.join(proxy.listen_ports, ", ")
    "#{length(proxy.instances)} instance(s) · Listen #{ports}"
  end

  defp proxy_detail(proxy),
    do: "#{proxy_subtitle(proxy)} · #{length(proxy.routes)} declared route(s)"

  defp proxy_traffic_label(proxy), do: "Traffic #{network_rate_label(proxy.rate)}"

  defp network_rate_label(nil), do: "not available"

  defp network_rate_label(rate) when is_map(rate) do
    received = Map.get(rate, :received)
    transmitted = Map.get(rate, :transmitted)

    if is_number(received) and is_number(transmitted),
      do: "Rx #{Format.rate(received)} · Tx #{Format.rate(transmitted)}",
      else: "I/O #{Format.rate(Map.get(rate, :rate))}"
  end

  defp network_rate_label(_rate), do: "not available"

  defp slot_cpu_label(%{cpu_pct: pct}) when is_number(pct), do: Format.percent(pct)
  defp slot_cpu_label(slot), do: cpu_usage(Map.get(slot, :metrics, %{}))

  # The service cards carry no status word: green/yellow/red/gray is the state.
  defp slot_ports_label(slot) do
    ports = Map.get(slot, :ports, [])
    ports = if ports == [], do: Map.get(slot, :config_ports, []), else: ports

    case ports do
      [port] when is_integer(port) -> "Port #{port}"
      ports when is_list(ports) and ports != [] -> "Ports #{Enum.join(ports, ", ")}"
      _ -> ""
    end
  end

  defp slot_ports_detail(slot) do
    case slot_ports_label(slot) do
      "" -> "Ports not reported"
      label -> label
    end
  end

  defp slot_detail(slot) do
    owner = Map.get(slot, :owner) || "Unplaced"

    "#{slot_metrics_label(slot)} · #{slot_ports_detail(slot)} · #{if(owner == "Unplaced", do: "Needs placement", else: "Owned by #{owner}")}"
  end

  defp cpu_usage(metrics) do
    cpu = Map.get(metrics, :cpu, %{})
    Format.cpu_percent(cpu)
  end

  defp memory_usage(metrics) do
    memory = Map.get(metrics, :memory, %{})
    used = if is_map(memory), do: Map.get(memory, :used), else: memory
    maximum = if is_map(memory), do: Map.get(memory, :total, Map.get(memory, :max)), else: nil

    cond do
      is_number(used) and is_number(maximum) -> "#{Format.bytes(used)} / #{Format.bytes(maximum)}"
      is_number(used) -> Format.bytes(used)
      true -> "unknown"
    end
  end

  defp list_label(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> case do
      [] -> "unknown"
      values -> Enum.join(values, ", ")
    end
  end

  defp list_label(value), do: to_string(value)

  defp ports_label(values), do: list_label(values)

  defp slot_label(slot) do
    service = slot_service(slot)
    slot_number = Map.get(slot, :slot, "unknown")
    unit = Map.get(slot, :unit, "unknown")
    owner = Map.get(slot, :owner)

    if owner,
      do: "#{service} slot #{slot_number} owned by #{owner} (#{unit})",
      else: "#{service} slot #{slot_number} unplaced (#{unit})"
  end

  defp status_class(status) when status in ["up", "running", "active", "ok", "healthy"],
    do: "is-live"

  defp status_class(status) when status in ["down", "failed"], do: "is-down"

  defp status_class(status)
       when status in [
              "degraded",
              "awaiting_heal",
              "draining",
              "starting",
              "activating",
              "reloading"
            ],
       do: "is-degraded"

  # Intentionally offline: the item is expected to be out of the running set.
  defp status_class(status)
       when status in ["maintenance", "offline", "disabled", "stopped", "inactive", "dead"],
       do: "is-offline"

  defp status_class(_), do: "is-unknown"

  defp node_class(node) do
    case Map.get(node, :availability) do
      availability when availability in ["maintenance", "disabled"] -> "is-offline"
      _ -> status_class(Map.get(node, :status))
    end
  end

  defp slot_class(slot) do
    if is_nil(Map.get(slot, :owner)),
      do: "is-unplaced",
      else: status_class(Map.get(slot, :status))
  end

  defp status_label(status) when status in [nil, "", "unknown"], do: "Unknown"

  defp status_label(status),
    do: status |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp truncate(value, limit) do
    value = to_string(value)
    if String.length(value) > limit, do: String.slice(value, 0, limit - 1) <> "…", else: value
  end
end
