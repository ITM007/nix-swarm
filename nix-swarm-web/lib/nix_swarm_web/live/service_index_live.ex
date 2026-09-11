defmodule NixSwarmWeb.ServiceIndexLive do
  @moduledoc "Read-only service ownership inventory."

  use NixSwarmWeb, :live_view

  alias NixSwarmWeb.{Format, InventoryHelpers, QueryBroker}

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
    <.app_shell id="services-page" current_path="/services">
      <header class="page-header">
        <p class="eyebrow">Read-only inventory</p>
        <h1>Services</h1>
        <p>Desired replicas, ownership, observed state, recovery contract, and current metrics.</p>
        <p class={"state-badge state-#{@state}"} role="status"><%= state_label(@state) %></p>
      </header>

      <%= if @snapshot do %>
        <%= if @snapshot.stale? do %><p class="notice notice-stale">Stale snapshot: values may be out of date.</p><% end %>
        <%= if @snapshot.errors != [] do %>
          <section class="notice notice-degraded" aria-labelledby="service-errors-heading">
            <h2 id="service-errors-heading">Degraded data</h2>
            <ul><%= for error <- @snapshot.errors do %><li><%= InventoryHelpers.error_text(error) %></li><% end %></ul>
          </section>
        <% end %>
        <%= if @snapshot.services == [] do %>
          <p role="status">No service data is currently known.</p>
        <% else %>
          <div class="table-wrap">
            <table class="table table-zebra">
              <caption>Cluster services</caption>
              <thead><tr><th scope="col">Service</th><th scope="col">Desired</th><th scope="col">State</th><th scope="col">Slots and owners</th><th scope="col">Recovery</th><th scope="col">Current metrics</th></tr></thead>
              <tbody>
                <%= for service <- sorted_services(@snapshot.services) do %>
                  <tr>
                    <th scope="row"><a href={service_href(service.name)}><%= service.name %></a></th>
                    <td><%= service.desired_replicas %> desired replicas</td>
                    <td><span class={"state-#{service.status}"}><%= InventoryHelpers.state_label(service.status) %></span><%= if service.awaiting_heal?, do: " · awaiting_heal" %></td>
                    <td><%= for slot <- service.slots do %><div><%= slot.unit %> — <%= Map.get(slot, :owner) || "Unplaced" %> — <%= InventoryHelpers.state_label(slot.status) %></div><% end %></td>
                    <td><%= contract_summary(service.state_contract) %></td>
                    <td><%= service_metrics(service.name, @snapshot) %></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      <% else %>
        <p role="status">Loading service status.</p>
      <% end %>
    </.app_shell>
    """
  end

  defp sorted_services(services), do: Enum.sort_by(services, &Map.get(&1, :name, ""))
  defp service_href(name), do: "/services/#{InventoryHelpers.encode_identifier(name)}"

  defp contract_summary(nil), do: "Unknown"

  defp contract_summary(contract) do
    auto_heal = InventoryHelpers.map_value(contract, :auto_heal, "unknown")
    grace = InventoryHelpers.map_value(contract, :heal_grace_sec, "unknown")
    restore = InventoryHelpers.map_value(contract, :restore, "unknown")
    dirs = contract |> InventoryHelpers.map_value(:dirs, []) |> length()
    "auto_heal #{auto_heal}; grace #{grace}s; restore #{restore}; dirs #{dirs}"
  end

  defp service_metrics(name, snapshot) do
    metrics =
      snapshot
      |> Map.get(:metrics, %{})
      |> InventoryHelpers.map_value(:services, %{})
      |> InventoryHelpers.map_value(name, %{})

    metrics
    |> Enum.map(fn {key, value} -> "#{key}: #{value_label(key, value)}" end)
    |> Enum.sort()
    |> Enum.join("; ")
    |> case do
      "" -> "Unknown"
      text -> text
    end
  end

  defp value_label(key, value) when key in [:cpu, "cpu"], do: Format.cpu_percent(value)
  defp value_label(_key, value) when is_map(value), do: inspect(value)
  defp value_label(_key, value), do: to_string(value)

  defp snapshot_state(nil), do: :loading
  defp snapshot_state(%{stale?: true}), do: :stale
  defp snapshot_state(%{errors: errors}) when errors != [], do: :degraded
  defp snapshot_state(%{services: []}), do: :unknown
  defp snapshot_state(_), do: :fresh

  defp state_label(:loading), do: "Loading"
  defp state_label(:fresh), do: "Fresh"
  defp state_label(:stale), do: "Stale"
  defp state_label(:degraded), do: "Degraded"
  defp state_label(:unknown), do: "Unknown"
end
