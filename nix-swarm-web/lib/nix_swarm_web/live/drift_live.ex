defmodule NixSwarmWeb.DriftLive do
  @moduledoc "Read-only desired/observed and configuration consistency findings."

  use NixSwarmWeb, :live_view

  alias NixSwarmWeb.{InventoryHelpers, QueryBroker}

  @severity_order ["error", "warning", "unknown", "info"]

  @doc "Returns normalized findings from one ClusterSnapshot."
  def findings(nil), do: []

  def findings(snapshot) do
    drift = Map.get(snapshot, :drift, %{})

    []
    |> add_consistency_finding(Map.get(drift, :config_consistent?))
    |> add_version_finding(Map.get(drift, :versions, %{}))
    |> add_desired_observed_finding(Map.get(drift, :desired_observed, %{}))
    |> add_diagnostics(Map.get(drift, :diagnostics, []))
    |> add_node_errors(snapshot)
    |> Enum.sort_by(fn finding ->
      {severity_rank(finding.severity), finding.kind, finding.detail}
    end)
  end

  @doc "Groups findings into stable severity buckets for rendering."
  def grouped_findings(snapshot) do
    buckets = Map.new(@severity_order, &{&1, []})

    Enum.reduce(findings(snapshot), buckets, fn finding, grouped ->
      Map.update(grouped, finding.severity, [finding], &[finding | &1])
    end)
    |> Map.new(fn {severity, values} -> {severity, Enum.reverse(values)} end)
  end

  @impl true
  def mount(_params, _session, socket) do
    snapshot = QueryBroker.snapshot()
    if connected?(socket), do: QueryBroker.subscribe()

    {:ok,
     assign(socket,
       snapshot: snapshot,
       state: snapshot_state(snapshot),
       groups: grouped_findings(snapshot),
       severity_order: @severity_order
     )}
  end

  @impl true
  def handle_info({:cluster_snapshot, snapshot}, socket) when is_map(snapshot) do
    {:noreply,
     assign(socket,
       snapshot: snapshot,
       state: snapshot_state(snapshot),
       groups: grouped_findings(snapshot),
       severity_order: @severity_order
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="drift-page">
      <header class="page-header">
        <p class="eyebrow">Read-only consistency</p>
        <h1>Configuration drift</h1>
        <p>Desired and observed differences are shown without treating missing data as healthy.</p>
        <p class={"state-badge state-#{@state}"} role="status"><%= state_label(@state) %></p>
      </header>

      <%= if @snapshot do %>
        <%= if @snapshot.drift.config_consistent? == true do %>
          <p class="notice notice-good">In sync: reported configuration digests agree.</p>
        <% end %>
        <%= if @snapshot.drift.config_consistent? == nil do %>
          <p class="notice notice-unknown">Unknown: not enough data to determine configuration consistency.</p>
        <% end %>
        <%= for severity <- @severity_order do %>
          <% entries = Map.get(@groups, severity, []) %>
          <%= if entries != [] do %>
            <section class={"drift-group severity-#{severity}"} aria-labelledby={"drift-#{severity}"}>
              <h2 id={"drift-#{severity}"}><%= String.capitalize(severity) %> findings</h2>
              <ul>
                <%= for finding <- entries do %>
                  <li>
                    <strong><%= finding.title %></strong>
                    <span> — <%= finding.detail %></span>
                    <%= if finding.affected != [] do %><small> (Affected: <%= Enum.join(finding.affected, ", ") %>)</small><% end %>
                  </li>
                <% end %>
              </ul>
            </section>
          <% end %>
        <% end %>
        <%= if Enum.all?(@groups, fn {_severity, entries} -> entries == [] end) and @snapshot.drift.config_consistent? == true do %>
          <p role="status">No drift findings.</p>
        <% end %>
      <% else %>
        <p role="status">Loading drift status.</p>
      <% end %>
    </main>
    """
  end

  defp add_consistency_finding(findings, false) do
    [
      %{
        severity: "error",
        kind: "config_digest",
        title: "Config digest mismatch",
        detail: "config digest mismatch",
        affected: []
      }
      | findings
    ]
  end

  defp add_consistency_finding(findings, nil) do
    [
      %{
        severity: "unknown",
        kind: "config_digest",
        title: "Config consistency unknown",
        detail: "not enough data to determine consistency",
        affected: []
      }
      | findings
    ]
  end

  defp add_consistency_finding(findings, _true), do: findings

  defp add_version_finding(findings, versions) when is_map(versions) do
    known =
      versions |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in ["", "unknown"]))

    if length(Enum.uniq(known)) > 1 do
      affected =
        versions
        |> Map.values()
        |> List.flatten()
        |> Enum.map(&to_string/1)
        |> Enum.uniq()
        |> Enum.sort()

      [
        %{
          severity: "warning",
          kind: "versions",
          title: "Mixed release versions",
          detail: Enum.join(Enum.uniq(known), ", "),
          affected: affected
        }
        | findings
      ]
    else
      findings
    end
  end

  defp add_version_finding(findings, _versions), do: findings

  defp add_desired_observed_finding(findings, observed) when is_map(observed) do
    drift = InventoryHelpers.map_value(observed, :drift, [])
    in_sync = InventoryHelpers.map_value(observed, :in_sync?, nil)

    cond do
      is_list(drift) and drift != [] ->
        Enum.reduce(drift, findings, fn item, acc ->
          item = if is_map(item), do: item, else: %{}
          field = InventoryHelpers.map_value(item, :field, "unknown field")
          desired = InventoryHelpers.map_value(item, :desired, "unknown")
          actual = InventoryHelpers.map_value(item, :observed, "unknown")

          [
            %{
              severity: "warning",
              kind: "desired_observed",
              title: "Desired/observed drift",
              detail: "#{field}: desired #{value_text(desired)}, observed #{value_text(actual)}",
              affected: []
            }
            | acc
          ]
        end)

      in_sync == false ->
        [
          %{
            severity: "warning",
            kind: "desired_observed",
            title: "Desired/observed drift",
            detail: "queried node reports desired and observed state differ",
            affected: []
          }
          | findings
        ]

      true ->
        findings
    end
  end

  defp add_desired_observed_finding(findings, _observed), do: findings

  defp add_diagnostics(findings, diagnostics) when is_list(diagnostics) do
    Enum.reduce(diagnostics, findings, fn diagnostic, acc ->
      diagnostic = if is_map(diagnostic), do: diagnostic, else: %{}

      severity =
        diagnostic |> InventoryHelpers.map_value(:severity, "warning") |> normalize_severity()

      reason = InventoryHelpers.map_value(diagnostic, :reason, "placement diagnostic")

      affected =
        [
          InventoryHelpers.map_value(diagnostic, :service, nil),
          InventoryHelpers.map_value(diagnostic, :node, nil)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&to_string/1)

      [
        %{
          severity: severity,
          kind: "placement",
          title: "Placement diagnostic",
          detail: to_string(reason),
          affected: affected
        }
        | acc
      ]
    end)
  end

  defp add_diagnostics(findings, _diagnostics), do: findings

  defp add_node_errors(findings, snapshot) do
    snapshot
    |> Map.get(:nodes, [])
    |> Enum.reduce(findings, fn node, acc ->
      if Map.get(node, :status) == "down" or Map.get(node, :error) do
        reason =
          node |> Map.get(:error, %{}) |> InventoryHelpers.map_value(:reason, "node unreachable")

        [
          %{
            severity: "error",
            kind: "node",
            title: "Unreachable node",
            detail: "node_unreachable: #{reason}",
            affected: [Map.get(node, :name, "unknown")]
          }
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp normalize_severity(value) when value in ["error", "warning", "unknown", "info"], do: value
  defp normalize_severity(_), do: "warning"

  defp severity_rank(value),
    do: Enum.find_index(@severity_order, &(&1 == value)) || length(@severity_order)

  defp value_text(value) when is_binary(value), do: value
  defp value_text(value) when is_atom(value), do: Atom.to_string(value)
  defp value_text(value), do: inspect(value)

  defp snapshot_state(nil), do: :loading
  defp snapshot_state(%{stale?: true}), do: :stale
  defp snapshot_state(%{errors: errors}) when errors != [], do: :degraded
  defp snapshot_state(_), do: :fresh

  defp state_label(:loading), do: "Loading"
  defp state_label(:fresh), do: "Fresh"
  defp state_label(:stale), do: "Stale"
  defp state_label(:degraded), do: "Degraded"
end
