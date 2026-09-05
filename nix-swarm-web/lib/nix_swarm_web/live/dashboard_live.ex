defmodule NixSwarmWeb.DashboardLive do
  @moduledoc "Read-only cluster status dashboard backed by QueryBroker broadcasts."

  use NixSwarmWeb, :live_view

  alias NixSwarmWeb.{Format, QueryBroker}
  import NixSwarmWeb.StatusComponents

  @nav [
    {"Dashboard", "/"},
    {"Network", "/network"},
    {"Nodes", "/nodes"},
    {"Services", "/services"},
    {"Drift", "/drift"},
    {"Logs", "/logs"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    broker = QueryBroker.broker_name()
    snapshot = QueryBroker.snapshot(broker)

    if connected?(socket) do
      QueryBroker.subscribe(broker)
    end

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       snapshot: snapshot,
       broker_status: QueryBroker.status(broker),
       just_refreshed?: false,
       nav: @nav
     )}
  end

  @impl true
  def handle_info({:cluster_snapshot, snapshot}, socket) when is_map(snapshot) do
    {:noreply,
     assign(socket,
       snapshot: snapshot,
       broker_status: QueryBroker.status(QueryBroker.broker_name()),
       just_refreshed?:
         Map.get(socket.assigns.snapshot || %{}, :stale?, false) and not snapshot.stale?
     )}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp state(nil), do: {"loading", "Loading"}

  defp state(snapshot) do
    summary = Map.get(snapshot, :summary, %{})
    drift = Map.get(snapshot, :drift, %{})

    cond do
      Map.get(snapshot, :stale?, false) -> {"stale", "Stale"}
      Map.get(summary, :live_nodes, 0) == 0 -> {"degraded", "Degraded"}
      Map.get(drift, :config_consistent?) == false -> {"degraded", "Degraded"}
      Map.get(snapshot, :errors, []) != [] -> {"degraded", "Degraded"}
      true -> {"healthy", "Healthy"}
    end
  end

  defp summary(snapshot) do
    Map.get(snapshot || %{}, :summary, %{})
  end

  defp config_label(snapshot) do
    case get_in(snapshot || %{}, [:drift, :config_consistent?]) do
      true -> "yes"
      false -> "no"
      _ -> "unknown"
    end
  end

  defp refresh_label(value) do
    case value do
      %{captured_at: %DateTime{} = date_time} -> DateTime.to_iso8601(date_time)
      _ -> "unknown"
    end
  end

  defp error_label(error) when is_map(error) do
    reason = Map.get(error, :reason, Map.get(error, "reason", "unknown error"))
    scope = Map.get(error, :scope, Map.get(error, "scope", "query"))
    "#{scope}: #{reason}"
  end

  defp error_label(error), do: to_string(error)

  defp metric(snapshot, group, key) do
    snapshot
    |> Map.get(:metrics, %{})
    |> Map.get(:cluster, %{})
    |> Map.get(group, %{})
    |> Map.get(key)
  end

  defp metric_label(value, format) do
    case format do
      :percent -> Format.percent(value)
      _ -> Format.bytes(value)
    end
  end

  defp snapshot_state(snapshot), do: state(snapshot)

  defp snapshot_state(snapshot, true) when is_map(snapshot) and not snapshot.stale?,
    do: {"fresh", "Fresh · Healthy"}

  defp snapshot_state(snapshot, _just_refreshed), do: snapshot_state(snapshot)
  defp state_tone({tone, _label}), do: tone
  defp state_label({_tone, label}), do: label

  @impl true
  def render(assigns) do
    ~H"""
    <main id="dashboard" class="dashboard" data-read-only="true">
      <header class="app-header">
        <div>
          <p class="eyebrow">NIX-SWARM</p>
          <h1>Cluster dashboard</h1>
        </div>
        <div class="header-status">
          <.status_badge label={state_label(snapshot_state(@snapshot, @just_refreshed?))} tone={state_tone(snapshot_state(@snapshot, @just_refreshed?))} />
          <span class="read-only">read-only</span>
        </div>
      </header>

      <nav class="app-nav" aria-label="Primary navigation">
        <%= for {label, path} <- @nav do %>
          <a href={path} class={if(path == "/", do: "active", else: nil)}><%= label %></a>
        <% end %>
      </nav>

      <%= if is_nil(@snapshot) do %>
        <section class="empty-state" aria-live="polite">
          <h2>Loading cluster status</h2>
          <p>The shared query broker is waiting for the first bounded snapshot.</p>
        </section>
      <% else %>
        <% counts = summary(@snapshot) %>
        <%= if Map.get(@snapshot, :stale?, false) do %>
          <section class="notice notice--stale" role="alert">
            <strong>Stale data</strong>
            <span>Showing the last good snapshot; the latest query failed.</span>
          </section>
        <% end %>

        <section class="summary-grid" aria-label="Cluster summary">
          <.summary_card label="Configured nodes" value={Map.get(counts, :configured_nodes, 0)} />
          <.summary_card label="Live nodes" value={Map.get(counts, :live_nodes, 0)} tone={if(Map.get(counts, :live_nodes, 0) == 0, do: "bad", else: "good")} />
          <.summary_card label="Placement nodes" value={Map.get(counts, :placement_nodes, 0)} />
          <.summary_card label="Services" value={Map.get(counts, :services, 0)} />
          <.summary_card label="Running services" value={Map.get(counts, :running_services, 0)} tone="good" />
          <.summary_card label="Degraded services" value={Map.get(counts, :degraded_services, 0)} tone={if(Map.get(counts, :degraded_services, 0) > 0, do: "bad", else: "good")} />
          <.summary_card label="Awaiting heal" value={Map.get(counts, :awaiting_heal_services, 0)} tone={if(Map.get(counts, :awaiting_heal_services, 0) > 0, do: "warn", else: "good")} />
          <.summary_card label="Config consistent" value={config_label(@snapshot)} tone={if(config_label(@snapshot) == "yes", do: "good", else: "warn")} />
        </section>

        <section class="detail-grid">
          <article class="panel">
            <h2>Refresh</h2>
            <dl class="facts">
              <div><dt>Queried node</dt><dd><%= @snapshot.queried_node %></dd></div>
              <div><dt>Last refresh</dt><dd><%= refresh_label(@snapshot) %></dd></div>
              <div><dt>Broker interval</dt><dd><%= Format.duration_ms(@broker_status.interval_ms) %></dd></div>
            </dl>
          </article>
          <article class="panel">
            <h2>Current metrics</h2>
            <div class="metrics">
              <.metric_value label="CPU" value={metric_label(metric(@snapshot, :cpu, :pct), :percent)} />
              <.metric_value label="Memory" value={metric_label(metric(@snapshot, :memory, :used), :bytes)} />
              <.metric_value label="Disk" value={metric_label(metric(@snapshot, :disk, :used), :bytes)} />
              <.metric_value label="Network received" value={metric_label(metric(@snapshot, :network, :received), :bytes)} />
            </div>
          </article>
        </section>

        <%= if Map.get(@snapshot, :errors, []) != [] do %>
          <section class="notice notice--error" role="alert">
            <h2>Query errors</h2>
            <ul>
              <%= for error <- @snapshot.errors do %>
                <li><%= error_label(error) %></li>
              <% end %>
            </ul>
          </section>
        <% end %>

        <%= if Map.get(counts, :live_nodes, 0) == 0 do %>
          <p class="degraded-copy">No live nodes are currently reporting.</p>
        <% end %>
      <% end %>
    </main>
    """
  end
end
