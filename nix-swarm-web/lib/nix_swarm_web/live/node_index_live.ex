defmodule NixSwarmWeb.NodeIndexLive do
  @moduledoc "Read-only node and machine inventory."

  use NixSwarmWeb, :live_view

  alias NixSwarmWeb.{InventoryHelpers, QueryBroker}

  @impl true
  def mount(_params, _session, socket) do
    snapshot = QueryBroker.snapshot()
    if connected?(socket), do: QueryBroker.subscribe()
    {:ok, assign(socket, snapshot: snapshot, state: snapshot_state(snapshot))}
  end

  @impl true
  def handle_info({:cluster_snapshot, snapshot}, socket) when is_map(snapshot) do
    {:noreply, assign(socket, snapshot: snapshot, state: snapshot_state(snapshot))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="nodes-page">
      <header class="page-header">
        <p class="eyebrow">Read-only inventory</p>
        <h1>Nodes</h1>
        <p>Configured and live machines, resources, networking, and locally owned units.</p>
        <p class={"state-badge state-#{@state}"} role="status"><%= state_label(@state) %></p>
      </header>

      <%= if @snapshot do %>
        <%= if @snapshot.stale? do %><p class="notice notice-stale">Stale snapshot: values may be out of date.</p><% end %>
        <%= if @snapshot.errors != [] do %>
          <section class="notice notice-degraded" aria-labelledby="node-errors-heading">
            <h2 id="node-errors-heading">Degraded data</h2>
            <ul><%= for error <- @snapshot.errors do %><li><%= InventoryHelpers.error_text(error) %></li><% end %></ul>
          </section>
        <% end %>
        <%= if @snapshot.nodes == [] do %>
          <p role="status">No node data is currently known.</p>
        <% else %>
          <div class="table-wrap">
            <table>
              <caption>Cluster nodes</caption>
              <thead>
                <tr><th scope="col">Node</th><th scope="col">Host</th><th scope="col">Liveness</th><th scope="col">Availability</th><th scope="col">Version</th><th scope="col">Config digest</th><th scope="col">Resources</th><th scope="col">Network</th><th scope="col">Owned units</th></tr>
              </thead>
              <tbody>
                <%= for node <- sorted_nodes(@snapshot.nodes) do %>
                  <tr>
                    <th scope="row"><a href={node_href(node.name)}><%= node.name %></a></th>
                    <td><%= node.host %></td>
                    <td><span class={"state-#{node.status}"}><%= InventoryHelpers.state_label(node.status) %></span><%= if node.error, do: " (#{node_error_label(node.error)})" %></td>
                    <td><%= InventoryHelpers.state_label(node.availability) %></td>
                    <td><%= node.version %><br /><small><%= node.build_version %></small></td>
                    <td><%= node.config_digest %></td>
                    <td><%= metrics_summary(node.metrics) %></td>
                    <td><%= network_summary(node.network_info) %></td>
                    <td><%= owned_unit_names(node.services) %></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      <% else %>
        <p role="status">Loading node status.</p>
      <% end %>
    </main>
    """
  end

  defp sorted_nodes(nodes), do: Enum.sort_by(nodes, &Map.get(&1, :name, ""))
  defp node_href(name), do: "/nodes/#{InventoryHelpers.encode_identifier(name)}"

  defp snapshot_state(nil), do: :loading
  defp snapshot_state(%{stale?: true}), do: :stale
  defp snapshot_state(%{errors: errors}) when errors != [], do: :degraded
  defp snapshot_state(%{nodes: []}), do: :unknown
  defp snapshot_state(_), do: :fresh

  defp state_label(:loading), do: "Loading"
  defp state_label(:fresh), do: "Fresh"
  defp state_label(:stale), do: "Stale"
  defp state_label(:degraded), do: "Degraded"
  defp state_label(:unknown), do: "Unknown"

  defp metrics_summary(metrics) do
    cpu =
      InventoryHelpers.metric_label(
        InventoryHelpers.map_value(InventoryHelpers.map_value(metrics, :cpu, %{}), :pct, nil),
        :percent
      )

    memory =
      InventoryHelpers.metric_label(
        InventoryHelpers.map_value(InventoryHelpers.map_value(metrics, :memory, %{}), :used, nil),
        :bytes
      )

    disk =
      InventoryHelpers.metric_label(
        InventoryHelpers.map_value(InventoryHelpers.map_value(metrics, :disk, %{}), :used, nil),
        :bytes
      )

    "CPU #{cpu}; memory #{memory}; disk #{disk}"
  end

  defp network_summary(info) do
    ips = info |> InventoryHelpers.map_value(:ips, []) |> Enum.join(", ")
    ports = info |> InventoryHelpers.map_value(:ports, []) |> Enum.join(", ")

    "#{if ips == "", do: "Unknown", else: ips} (ports #{if ports == "", do: "Unknown", else: ports})"
  end

  defp owned_unit_names(services) do
    services
    |> Enum.flat_map(&Map.get(&1, :units, []))
    |> Enum.map(&Map.get(&1, :unit, "unknown"))
    |> Enum.join(", ")
    |> case do
      "" -> "None known"
      names -> names
    end
  end

  defp node_error_label(error) do
    code = InventoryHelpers.map_value(error, :error, nil)
    reason = InventoryHelpers.map_value(error, :reason, "unknown")
    if code, do: "#{code}: #{reason}", else: to_string(reason)
  end
end
