defmodule NixSwarmWeb.NodeShowLive do
  @moduledoc "Read-only detail view for one current-snapshot node."

  use NixSwarmWeb, :live_view

  alias NixSwarmWeb.{InventoryHelpers, LogSearch, QueryBroker}

  @impl true
  def mount(params, session, socket) do
    requested =
      case params do
        params when is_map(params) ->
          Map.get(params, "node", if(is_map(session), do: Map.get(session, "node", ""), else: ""))

        _ ->
          if(is_map(session), do: Map.get(session, "node", ""), else: "")
      end

    snapshot = QueryBroker.snapshot()
    node = find_node(snapshot, requested)
    if connected?(socket), do: QueryBroker.subscribe()

    {:ok,
     assign(socket,
       snapshot: snapshot,
       node: node,
       requested: requested,
       state: snapshot_state(snapshot),
       logs: nil,
       fetched_at: nil,
       log_error: nil,
       log_lines: 200
     )}
  end

  @impl true
  def handle_info({:cluster_snapshot, snapshot}, socket) when is_map(snapshot) do
    node = find_node(snapshot, socket.assigns.requested)
    {:noreply, assign(socket, snapshot: snapshot, node: node, state: snapshot_state(snapshot))}
  end

  @impl true
  def handle_event("load_logs", _params, %{assigns: %{node: nil}} = socket) do
    {:noreply, assign(socket, log_error: "Unknown node; logs were not requested.")}
  end

  def handle_event("load_logs", params, socket) do
    lines = InventoryHelpers.bounded_lines(Map.get(params, "lines"), socket.assigns.log_lines)
    node_name = socket.assigns.node.name

    case QueryBroker.logs(QueryBroker.broker_name(), :node, node_name, lines) do
      {:ok, response} ->
        {:noreply,
         assign(socket,
           logs: LogSearch.lines_from_response(response),
           fetched_at: DateTime.utc_now(),
           log_lines: lines,
           log_error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, log_error: to_string(reason), log_lines: lines)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="node-show-page">
      <p><a href="/nodes">Back to nodes</a></p>
      <%= if @node do %>
        <header class="page-header">
          <p class="eyebrow">Node detail</p>
          <h1><%= @node.name %></h1>
          <p><%= @node.host %> · <%= InventoryHelpers.state_label(@node.status) %> · <%= InventoryHelpers.state_label(@node.availability) %></p>
          <p class={"state-badge state-#{@state}"} role="status"><%= state_label(@state) %></p>
        </header>

        <section aria-labelledby="node-health-heading">
          <h2 id="node-health-heading">Health and version</h2>
          <dl class="details-grid">
            <dt>Version</dt><dd><%= @node.version %></dd>
            <dt>Build version</dt><dd><%= @node.build_version %></dd>
            <dt>Release version</dt><dd><%= @node.release_version %></dd>
            <dt>Config digest</dt><dd><%= @node.config_digest %></dd>
            <dt>Uptime</dt><dd><%= uptime_label(@node.metrics.uptime) %></dd>
            <dt>CPU</dt><dd><%= metric(@node.metrics.cpu, :pct, :percent) %></dd>
            <dt>Memory</dt><dd><%= metric(@node.metrics.memory, :used, :bytes) %></dd>
            <dt>Disk</dt><dd><%= metric(@node.metrics.disk, :used, :bytes) %></dd>
            <dt>Network</dt><dd><%= network_label(@node.network_info) %></dd>
          </dl>
        </section>

        <section aria-labelledby="owned-units-heading">
          <h2 id="owned-units-heading">Owned units</h2>
          <%= if owned_units(@node) == [] do %>
            <p>None known.</p>
          <% else %>
            <ul><%= for unit <- owned_units(@node) do %><li><%= unit.unit %> — <%= InventoryHelpers.state_label(unit.status) %></li><% end %></ul>
          <% end %>
        </section>

        <section aria-labelledby="node-logs-heading">
          <h2 id="node-logs-heading">Node logs</h2>
          <button type="button" phx-click="load_logs" phx-value-lines={@log_lines}>Refresh node logs (200 lines)</button>
          <%= if @log_error do %><p class="notice notice-degraded" role="alert">Partial log result: <%= @log_error %></p><% end %>
          <%= if @logs do %>
            <p>Source <%= @node.name %> · Fetched <%= format_time(@fetched_at) %></p>
            <ol class="log-lines"><%= for line <- @logs do %><li><%= line %></li><% end %></ol>
          <% else %>
            <p>No logs loaded. Refresh explicitly to request the bounded current result.</p>
          <% end %>
        </section>
      <% else %>
        <header class="page-header"><h1>Unknown node</h1><p>The requested node is not present in the current snapshot.</p></header>
      <% end %>
    </main>
    """
  end

  defp find_node(nil, _requested), do: nil

  defp find_node(snapshot, requested) do
    name = InventoryHelpers.decode_identifier(requested)
    Enum.find(Map.get(snapshot, :nodes, []), &(&1.name == name))
  end

  defp owned_units(node) do
    node.services
    |> Enum.flat_map(&Map.get(&1, :units, []))
    |> Enum.sort_by(&{Map.get(&1, :slot) || 1_000_000, Map.get(&1, :unit, "")})
  end

  defp metric(metrics, key, kind) do
    metrics
    |> InventoryHelpers.map_value(key, nil)
    |> InventoryHelpers.metric_label(kind)
  end

  defp network_label(info) do
    ips = info |> InventoryHelpers.map_value(:ips, []) |> Enum.join(", ")
    ports = info |> InventoryHelpers.map_value(:ports, []) |> Enum.join(", ")

    "IPs #{if ips == "", do: "Unknown", else: ips}; ports #{if ports == "", do: "Unknown", else: ports}"
  end

  defp uptime_label(value) when is_number(value), do: "#{value} seconds"
  defp uptime_label(_), do: "Unknown"

  defp format_time(nil), do: "unknown time"
  defp format_time(value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")

  defp snapshot_state(nil), do: :loading
  defp snapshot_state(%{stale?: true}), do: :stale
  defp snapshot_state(%{errors: errors}) when errors != [], do: :degraded
  defp snapshot_state(_), do: :fresh

  defp state_label(:loading), do: "Loading"
  defp state_label(:fresh), do: "Fresh"
  defp state_label(:stale), do: "Stale"
  defp state_label(:degraded), do: "Degraded"
end
