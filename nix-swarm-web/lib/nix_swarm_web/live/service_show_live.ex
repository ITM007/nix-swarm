defmodule NixSwarmWeb.ServiceShowLive do
  @moduledoc "Read-only detail view for one current-snapshot service."

  use NixSwarmWeb, :live_view

  alias NixSwarmWeb.{Format, InventoryHelpers, LogSearch, QueryBroker}

  @impl true
  def mount(params, session, socket) do
    requested =
      case params do
        params when is_map(params) ->
          Map.get(
            params,
            "service",
            if(is_map(session), do: Map.get(session, "service", ""), else: "")
          )

        _ ->
          if(is_map(session), do: Map.get(session, "service", ""), else: "")
      end

    snapshot = QueryBroker.snapshot()
    service = find_service(snapshot, requested)
    if connected?(socket), do: QueryBroker.subscribe()

    {:ok,
     assign(socket,
       snapshot: snapshot,
       service: service,
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
    service = find_service(snapshot, socket.assigns.requested)

    {:noreply,
     assign(socket, snapshot: snapshot, service: service, state: snapshot_state(snapshot))}
  end

  @impl true
  def handle_event("load_logs", _params, %{assigns: %{service: nil}} = socket) do
    {:noreply, assign(socket, log_error: "Unknown service; logs were not requested.")}
  end

  def handle_event("load_logs", params, socket) do
    lines = InventoryHelpers.bounded_lines(Map.get(params, "lines"), socket.assigns.log_lines)
    service_name = socket.assigns.service.name

    case QueryBroker.logs(QueryBroker.broker_name(), :service, service_name, lines) do
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
    <.app_shell id="service-show-page" current_path="/services">
      <p><a href="/services">Back to services</a></p>
      <%= if @service do %>
        <header class="page-header">
          <p class="eyebrow">Service detail</p>
          <h1>Service <%= @service.name %></h1>
          <p><%= @service.desired_replicas %> desired replicas · <%= InventoryHelpers.state_label(@service.status) %></p>
          <p class={"state-badge state-#{@state}"} role="status"><%= state_label(@state) %></p>
        </header>

        <section aria-labelledby="service-slots-heading">
          <h2 id="service-slots-heading">Slots and ownership</h2>
          <table class="table table-zebra">
            <caption>Every desired and observed service slot</caption>
            <thead><tr><th scope="col">Slot</th><th scope="col">Owner</th><th scope="col">Unit</th><th scope="col">Observed state</th><th scope="col">Metrics</th></tr></thead>
            <tbody>
              <%= for slot <- @service.slots do %>
                <tr>
                  <th scope="row"><%= Map.get(slot, :slot, "unknown") %></th>
                  <td><%= Map.get(slot, :owner) || "Unplaced" %></td>
                  <td><%= slot.unit %></td>
                  <td><%= InventoryHelpers.state_label(slot.status) %><%= if slot.status in ["awaiting_heal", "awaiting-heal"], do: " (Awaiting heal)" %></td>
                  <td><%= metrics_label(slot.metrics) %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </section>

        <section aria-labelledby="service-contract-heading">
          <h2 id="service-contract-heading">State contract</h2>
          <%= if @service.state_contract do %>
            <dl class="details-grid">
              <dt>Auto heal</dt><dd><%= InventoryHelpers.map_value(@service.state_contract, :auto_heal, "Unknown") %></dd>
              <dt>Heal grace</dt><dd><%= InventoryHelpers.map_value(@service.state_contract, :heal_grace_sec, "Unknown") %> seconds</dd>
              <dt>Restore</dt><dd><%= InventoryHelpers.map_value(@service.state_contract, :restore, "Unknown") %></dd>
              <dt>Directories</dt><dd><%= @service.state_contract |> InventoryHelpers.map_value(:dirs, []) |> length() %></dd>
            </dl>
          <% else %><p>Unknown; no state contract was returned.</p><% end %>
        </section>

        <section aria-labelledby="service-logs-heading">
          <h2 id="service-logs-heading">Service logs</h2>
          <button class="btn btn-primary" type="button" phx-click="load_logs" phx-value-lines={@log_lines}>Refresh service logs (200 lines)</button>
          <%= if @log_error do %><p class="notice notice-degraded" role="alert">Partial log result: <%= @log_error %></p><% end %>
          <%= if @logs do %>
            <p>Source service <%= @service.name %> · Fetched <%= format_time(@fetched_at) %></p>
            <ol class="log-lines"><%= for line <- @logs do %><li><%= line %></li><% end %></ol>
          <% else %><p>No logs loaded. Refresh explicitly to request the bounded current result.</p><% end %>
        </section>
      <% else %>
        <header class="page-header"><h1>Unknown service</h1><p>The requested service is not present in the current snapshot.</p></header>
      <% end %>
    </.app_shell>
    """
  end

  defp find_service(nil, _requested), do: nil

  defp find_service(snapshot, requested) do
    name = InventoryHelpers.decode_identifier(requested)
    Enum.find(Map.get(snapshot, :services, []), &(&1.name == name))
  end

  defp metrics_label(metrics) do
    metrics
    |> Enum.map(fn {key, value} -> "#{key}: #{metric_value_label(key, value)}" end)
    |> Enum.sort()
    |> Enum.join("; ")
    |> case do
      "" -> "Unknown"
      value -> value
    end
  end

  defp metric_value_label(key, value) when key in [:cpu, "cpu"], do: Format.cpu_percent(value)
  defp metric_value_label(_key, value), do: to_string(value)

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
