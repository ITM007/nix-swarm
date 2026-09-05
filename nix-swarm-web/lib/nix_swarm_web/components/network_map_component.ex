defmodule NixSwarmWeb.NetworkMapComponent do
  @moduledoc "Deterministic, keyboard-readable SVG projection of cluster ownership."

  use Phoenix.Component

  attr(:snapshot, :map, required: true)

  @width 960
  @node_x 24
  @slot_x 560
  @card_width 330
  @card_height 52
  @top 54
  @gap 16

  @doc "Renders the network and ownership map with a table fallback."
  def network_map(assigns) do
    snapshot = Map.get(assigns, :snapshot, %{})
    nodes = snapshot |> Map.get(:nodes, []) |> Enum.sort_by(&Map.get(&1, :name, ""))

    slots =
      snapshot
      |> Map.get(:services, [])
      |> Enum.sort_by(&Map.get(&1, :name, ""))
      |> Enum.flat_map(fn service ->
        service
        |> Map.get(:slots, [])
        |> Enum.map(&Map.put(&1, :service, Map.get(service, :name, "unknown")))
      end)
      |> Enum.sort_by(fn slot ->
        {slot_name(slot), Map.get(slot, :slot) || 1_000_000, Map.get(slot, :unit, "")}
      end)

    node_positions =
      nodes
      |> Enum.with_index()
      |> Map.new(fn {node, index} ->
        {Map.get(node, :name, "unknown"), %{x: @node_x, y: @top + index * (@card_height + @gap)}}
      end)

    slot_positions =
      slots
      |> Enum.with_index()
      |> Map.new(fn {slot, index} ->
        {slot_key(slot), %{x: @slot_x, y: @top + index * (@card_height + @gap)}}
      end)

    height = max(@top + max(length(nodes), length(slots)) * (@card_height + @gap) + 34, 150)

    assigns =
      assigns
      |> assign(:snapshot, snapshot)
      |> assign(:nodes, nodes)
      |> assign(:slots, slots)
      |> assign(:node_positions, node_positions)
      |> assign(:slot_positions, slot_positions)
      |> assign(:width, @width)
      |> assign(:card_width, @card_width)
      |> assign(:card_height, @card_height)
      |> assign(:height, height)

    ~H"""
    <section class="network-map" aria-labelledby="network-map-title">
      <h2 id="network-map-title">Network and ownership map</h2>
      <p id="network-map-description" class="visually-hidden">
        Sorted node cards connect to service-slot cards when an owner is known. Unplaced slots remain visible without an edge.
      </p>
      <%= if @nodes == [] and @slots == [] do %>
        <p role="status">No nodes are currently reported.</p>
      <% else %>
        <svg role="img" aria-labelledby="network-map-title network-map-description" viewBox={"0 0 #{@width} #{@height}"} width={@width} height={@height}>
          <title>Cluster nodes and service ownership</title>
          <desc>Network addresses and service-slot ownership for the current cluster snapshot.</desc>
          <%= for slot <- @slots do %>
            <%= if owner = Map.get(slot, :owner) do %>
              <%= if from = Map.get(@node_positions, owner) do %>
                <% to = Map.fetch!(@slot_positions, slot_key(slot)) %>
                <line x1={from.x + @card_width} y1={from.y + @card_height / 2} x2={to.x} y2={to.y + @card_height / 2} class="ownership-edge" aria-label={edge_label(slot, owner)} />
              <% end %>
            <% end %>
          <% end %>
          <%= for node <- @nodes do %>
            <% position = Map.fetch!(@node_positions, Map.get(node, :name, "unknown")) %>
            <a href={node_href(Map.get(node, :name, "unknown"))} aria-label={node_label(node)}>
              <rect x={position.x} y={position.y} width={@card_width} height={@card_height} rx="6" class={"network-node #{status_class(Map.get(node, :status))}"} />
              <text x={position.x + 12} y={position.y + 21} class="network-node-name"><%= truncate(Map.get(node, :name, "unknown"), 38) %></text>
              <text x={position.x + 12} y={position.y + 40} class="network-node-meta"><%= truncate(node_meta(node), 48) %></text>
              <title><%= node_label(node) %></title>
            </a>
          <% end %>
          <%= for slot <- @slots do %>
            <% position = Map.fetch!(@slot_positions, slot_key(slot)) %>
            <% service = Map.get(slot, :service, "unknown") %>
            <% owner = Map.get(slot, :owner) %>
            <a href={service_href(service)} aria-label={slot_label(slot)}>
              <rect x={position.x} y={position.y} width={@card_width} height={@card_height} rx="6" class={"network-slot #{slot_class(slot)}"} />
              <text x={position.x + 12} y={position.y + 21} class="network-slot-name"><%= truncate(Map.get(slot, :unit, "unknown"), 38) %></text>
              <text x={position.x + 12} y={position.y + 40} class="network-slot-meta"><%= if owner, do: "#{service} · #{truncate(owner, 28)}", else: "#{service} · Unplaced" %></text>
              <title><%= slot_label(slot) %></title>
            </a>
          <% end %>
        </svg>
      <% end %>

      <table class="network-map-table">
        <caption>Accessible ownership table</caption>
        <thead><tr><th scope="col">Service slot</th><th scope="col">Owner</th><th scope="col">State</th></tr></thead>
        <tbody>
          <%= for slot <- @slots do %>
            <tr>
              <th scope="row"><a href={service_href(Map.get(slot, :service, "unknown"))}><%= Map.get(slot, :unit, "unknown") %></a></th>
              <td><%= Map.get(slot, :owner) || "Unplaced" %></td>
              <td><%= status_label(Map.get(slot, :status)) %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </section>
    """
  end

  defp slot_name(slot), do: Map.get(slot, :service, "unknown")

  defp slot_key(slot),
    do:
      {Map.get(slot, :service, "unknown"), Map.get(slot, :slot), Map.get(slot, :unit, "unknown")}

  defp edge_label(slot, owner),
    do:
      "#{Map.get(slot, :service, "unknown")} slot #{Map.get(slot, :slot, "unknown")} owned by #{owner}"

  defp node_label(node) do
    "Node #{Map.get(node, :name, "unknown")}, #{node_meta(node)}"
  end

  defp node_meta(node) do
    host = Map.get(node, :host, "unknown")
    status = status_label(Map.get(node, :status))
    ips = node |> Map.get(:network_info, %{}) |> Map.get(:ips, []) |> Enum.map(&to_string/1)

    case Enum.join(ips, ", ") do
      "" -> "#{host} · #{status}"
      addresses -> "#{host} · #{addresses} · #{status}"
    end
  end

  defp slot_label(slot) do
    service = Map.get(slot, :service, "unknown")
    slot_number = Map.get(slot, :slot, "unknown")
    unit = Map.get(slot, :unit, "unknown")
    owner = Map.get(slot, :owner)

    if owner,
      do: "#{service} slot #{slot_number} owned by #{owner} (#{unit})",
      else: "#{service} slot #{slot_number} unplaced (#{unit})"
  end

  defp node_href(name), do: "/nodes/#{Base.url_encode64(to_string(name), padding: false)}"
  defp service_href(name), do: "/services/#{Base.url_encode64(to_string(name), padding: false)}"

  defp status_class(status) when status in ["down", "failed"], do: "is-down"
  defp status_class(status) when status in ["degraded", "awaiting_heal"], do: "is-degraded"
  defp status_class(_), do: "is-unknown"

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
