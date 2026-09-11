defmodule NixSwarmWeb.LogsLive do
  @moduledoc "Read-only bounded logs with literal search and severity filters."

  use NixSwarmWeb, :live_view

  alias NixSwarmWeb.{InventoryHelpers, LogSearch, QueryBroker}

  @impl true
  def mount(_params, _session, socket) do
    snapshot = QueryBroker.snapshot()
    target = if snapshot, do: snapshot.queried_node, else: ""
    if connected?(socket), do: QueryBroker.subscribe()

    {:ok,
     assign(socket,
       snapshot: snapshot,
       state: snapshot_state(snapshot),
       scope: "cluster",
       target: target,
       lines: 200,
       raw_lines: [],
       result: nil,
       fetched_at: nil,
       log_error: nil
     )}
  end

  @impl true
  def handle_info({:cluster_snapshot, snapshot}, socket) when is_map(snapshot) do
    target =
      if socket.assigns.target in ["", "unknown"],
        do: snapshot.queried_node,
        else: socket.assigns.target

    {:noreply,
     assign(socket, snapshot: snapshot, target: target, state: snapshot_state(snapshot))}
  end

  @impl true
  def handle_event("refresh", params, socket) do
    scope = Map.get(params, "scope", socket.assigns.scope)
    target = Map.get(params, "target", socket.assigns.target)
    lines = InventoryHelpers.bounded_lines(Map.get(params, "lines"), 200)

    case scope_request(scope) do
      {:ok, scope_atom} ->
        case QueryBroker.logs(QueryBroker.broker_name(), scope_atom, target, lines) do
          {:ok, response} ->
            raw_lines = LogSearch.lines_from_response(response)
            result = LogSearch.search(raw_lines, "", filter: "all")

            {:noreply,
             assign(socket,
               scope: scope,
               target: target,
               lines: lines,
               raw_lines: raw_lines,
               result: result,
               fetched_at: DateTime.utc_now(),
               log_error: nil
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               scope: scope,
               target: target,
               lines: lines,
               log_error: to_string(reason)
             )}
        end

      :error ->
        {:noreply,
         assign(socket,
           scope: scope,
           target: target,
           lines: lines,
           log_error: "invalid log scope"
         )}
    end
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    result =
      LogSearch.search(
        socket.assigns.raw_lines,
        (socket.assigns.result && socket.assigns.result.query) || "",
        filter: filter
      )

    {:noreply, assign(socket, result: result)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    filter = if socket.assigns.result, do: socket.assigns.result.filter, else: "all"

    {:noreply,
     assign(socket, result: LogSearch.search(socket.assigns.raw_lines, query, filter: filter))}
  end

  def handle_event("next_match", _params, %{assigns: %{result: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("next_match", _params, socket),
    do: {:noreply, assign(socket, result: LogSearch.next_match(socket.assigns.result))}

  def handle_event("previous_match", _params, %{assigns: %{result: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("previous_match", _params, socket),
    do: {:noreply, assign(socket, result: LogSearch.previous_match(socket.assigns.result))}

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell id="logs-page" current_path="/logs">
      <header class="page-header">
        <p class="eyebrow">Read-only observability</p>
        <h1>Logs</h1>
        <p>Only the bounded current result is searched. Search terms are literal substrings, never regular expressions.</p>
        <p class={"state-badge state-#{@state}"} role="status"><%= state_label(@state) %></p>
      </header>

      <form id="log-controls" phx-submit="refresh">
        <label>Scope
          <select class="select select-bordered" name="scope">
            <option value="cluster" selected={@scope == "cluster"}>Cluster</option>
            <option value="node" selected={@scope == "node"}>Node</option>
            <option value="service" selected={@scope == "service"}>Service</option>
          </select>
        </label>
        <label>Target <input class="input input-bordered" name="target" value={@target} /></label>
        <label>Lines (1–1000) <input class="input input-bordered" name="lines" value={@lines} inputmode="numeric" /></label>
        <button class="btn btn-primary" type="submit">Refresh logs</button>
      </form>

      <%= if @snapshot && @snapshot.stale? do %><p class="notice notice-stale">Stale cluster snapshot: log source selection may be out of date.</p><% end %>
      <%= if @log_error do %><p class="notice notice-degraded" role="alert">Partial log result: <%= @log_error %></p><% end %>

      <section aria-labelledby="log-search-heading">
        <h2 id="log-search-heading">Current result filters</h2>
        <form phx-submit="search">
          <label>Literal search <input class="input input-bordered" name="query" value={if @result, do: @result.query, else: ""} /></label>
          <button class="btn btn-primary" type="submit">Search</button>
        </form>
        <div class="log-filter-buttons" role="group" aria-label="Log severity filter">
          <button class="btn btn-outline btn-sm" type="button" phx-click="filter" phx-value-filter="all">All</button>
          <button class="btn btn-outline btn-sm" type="button" phx-click="filter" phx-value-filter="warnings-errors">Warnings/errors</button>
          <button class="btn btn-outline btn-sm" type="button" phx-click="filter" phx-value-filter="warnings">Warnings</button>
          <button class="btn btn-outline btn-sm" type="button" phx-click="filter" phx-value-filter="errors">Errors</button>
        </div>
        <button class="btn btn-ghost btn-sm" type="button" phx-click="previous_match">Previous match</button>
        <button class="btn btn-ghost btn-sm" type="button" phx-click="next_match">Next match</button>
      </section>

      <%= if @result do %>
        <section aria-labelledby="log-result-heading">
          <h2 id="log-result-heading">Log result</h2>
          <p>Source <%= @target %> (<%= @scope %>) · Fetched <%= format_time(@fetched_at) %> · <%= length(@result.lines) %> lines</p>
          <p><%= match_summary(@result) %></p>
          <ol class="log-lines"><%= for {line, index} <- Enum.with_index(@result.lines) do %><li class={if current_line(@result) == index, do: "current-match", else: nil}><%= line %></li><% end %></ol>
        </section>
      <% else %>
        <p role="status">No logs loaded. The default request is 200 lines; refresh explicitly to query a scope.</p>
      <% end %>
    </.app_shell>
    """
  end

  defp scope_request("cluster"), do: {:ok, :cluster}
  defp scope_request("node"), do: {:ok, :node}
  defp scope_request("service"), do: {:ok, :service}
  defp scope_request(_), do: :error

  defp current_line(%{matches: [], current_match: _}), do: nil

  defp current_line(%{matches: matches, current_match: index}) when is_integer(index),
    do: Enum.at(matches, index)

  defp current_line(_), do: nil

  defp match_summary(%{matches: []}), do: "0 matches"

  defp match_summary(%{matches: matches, current_match: current}),
    do:
      "#{length(matches)} match#{if length(matches) == 1, do: "", else: "es"} · Match #{(current || 0) + 1} of #{length(matches)}"

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
