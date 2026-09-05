defmodule NixSwarmWeb.NetworkLive do
  @moduledoc "Read-only network and ownership view."

  use NixSwarmWeb, :live_view

  alias NixSwarmWeb.{NetworkMapComponent, QueryBroker}

  @impl true
  def mount(_params, _session, socket) do
    snapshot = QueryBroker.snapshot()

    if connected?(socket), do: QueryBroker.subscribe()

    {:ok,
     socket
     |> assign(:snapshot, snapshot)
     |> assign(:state, snapshot_state(snapshot))}
  end

  @impl true
  def handle_info({:cluster_snapshot, snapshot}, socket) when is_map(snapshot) do
    {:noreply, assign(socket, snapshot: snapshot, state: snapshot_state(snapshot))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="network-page">
      <header class="page-header">
        <p class="eyebrow">Read-only inventory</p>
        <h1>Network</h1>
        <p>Node liveness, network addresses, and service ownership.</p>
        <p class={"state-badge state-#{@state}"} role="status"><%= state_label(@state) %></p>
      </header>

      <%= if @snapshot do %>
        <%= if @snapshot.stale? do %>
          <p class="notice notice-stale">Stale: showing the last usable snapshot while the query broker recovers.</p>
        <% end %>
        <%= if @snapshot.errors != [] do %>
          <section class="notice notice-degraded" aria-labelledby="network-errors-heading">
            <h2 id="network-errors-heading">Degraded data</h2>
            <ul><%= for error <- @snapshot.errors do %><li><%= error_text(error) %></li><% end %></ul>
          </section>
        <% end %>
        <NetworkMapComponent.network_map snapshot={@snapshot} />
      <% else %>
        <p role="status">Loading network status.</p>
      <% end %>
    </main>
    """
  end

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

  defp error_text(error) when is_map(error) do
    scope = Map.get(error, :scope, Map.get(error, "scope", "query"))
    reason = Map.get(error, :reason, Map.get(error, "reason", "unknown"))
    "#{scope}: #{reason}"
  end

  defp error_text(error), do: to_string(error)
end
