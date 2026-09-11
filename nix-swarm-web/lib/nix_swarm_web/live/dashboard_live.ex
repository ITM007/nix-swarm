defmodule NixSwarmWeb.DashboardLive do
  @moduledoc "Read-only cluster status dashboard backed by QueryBroker broadcasts."

  use NixSwarmWeb, :live_view

  alias NixSwarmWeb.{
    ConfigSource,
    Format,
    MachineEnrollment,
    NetworkMapComponent,
    NixHighlighter,
    QueryBroker
  }

  import NixSwarmWeb.StatusComponents

  @impl true
  def mount(_params, _session, socket) do
    broker = QueryBroker.broker_name()
    snapshot = QueryBroker.snapshot(broker)
    config_source = ConfigSource.load()

    if connected?(socket) do
      QueryBroker.subscribe(broker)
    end

    {:ok,
     assign(socket,
       page_title: "Cluster map",
       snapshot: snapshot,
       broker_status: QueryBroker.status(broker),
       just_refreshed?: false,
       enrollment_open?: false,
       enrollment: nil,
       enrollment_errors: [],
       machine_params: machine_params(snapshot),
       config_source: config_source,
       service_ports: configured_service_ports(config_source, snapshot),
       config_open?: true,
       config_file: nil,
       config_notice: nil,
       config_modal_open?: false,
       config_groups_collapsed: MapSet.new()
     )}
  end

  @impl true
  def handle_info({:cluster_snapshot, snapshot}, socket) when is_map(snapshot) do
    {:noreply,
     assign(socket,
       snapshot: snapshot,
       broker_status: QueryBroker.status(QueryBroker.broker_name()),
       service_ports: configured_service_ports(socket.assigns.config_source, snapshot),
       just_refreshed?:
         Map.get(socket.assigns.snapshot || %{}, :stale?, false) and not snapshot.stale?
     )}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_machine_enrollment", _params, socket) do
    {:noreply, assign(socket, enrollment_open?: true, enrollment: nil, enrollment_errors: [])}
  end

  def handle_event("close_machine_enrollment", _params, socket) do
    {:noreply, assign(socket, enrollment_open?: false)}
  end

  def handle_event("toggle_config_section", _params, socket) do
    {:noreply, assign(socket, config_open?: not socket.assigns.config_open?)}
  end

  def handle_event("toggle_config_group", %{"group" => group}, socket) when is_binary(group) do
    collapsed = socket.assigns.config_groups_collapsed

    next =
      if MapSet.member?(collapsed, group),
        do: MapSet.delete(collapsed, group),
        else: MapSet.put(collapsed, group)

    {:noreply, assign(socket, config_groups_collapsed: next)}
  end

  def handle_event("open_config_file", %{"rel" => rel}, socket) when is_binary(rel) do
    {:noreply, socket |> load_config_file(rel) |> assign(config_notice: nil)}
  end

  def handle_event("map_item_selected", %{"kind" => kind, "key" => key}, socket)
      when is_binary(kind) and is_binary(key) do
    source = socket.assigns.config_source

    case ConfigSource.resolve(source, kind, key) do
      nil ->
        {:noreply,
         assign(socket,
           config_open?: true,
           config_file: nil,
           config_notice: "No .nix file maps to #{kind} \"#{key}\" in this source."
         )}

      rel ->
        {:noreply,
         socket
         |> load_config_file(rel)
         |> assign(config_open?: true, config_notice: nil)}
    end
  end

  def handle_event("map_item_selected", _params, socket), do: {:noreply, socket}

  def handle_event("close_config_file", _params, socket) do
    {:noreply, assign(socket, config_file: nil, config_modal_open?: false)}
  end

  def handle_event("open_config_modal", _params, %{assigns: %{config_file: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("open_config_modal", _params, socket) do
    {:noreply, assign(socket, config_modal_open?: true)}
  end

  def handle_event("close_config_modal", _params, socket) do
    {:noreply, assign(socket, config_modal_open?: false)}
  end

  def handle_event("generate_machine_config", %{"machine" => params}, socket) do
    case MachineEnrollment.generate(params) do
      {:ok, enrollment} ->
        {:noreply,
         assign(socket,
           enrollment: enrollment,
           enrollment_errors: [],
           machine_params: params,
           enrollment_open?: true
         )}

      {:error, errors} ->
        {:noreply,
         assign(socket,
           enrollment: nil,
           enrollment_errors: errors,
           machine_params: params,
           enrollment_open?: true
         )}
    end
  end

  def handle_event("generate_machine_config", _params, socket) do
    {:noreply,
     assign(socket,
       enrollment: nil,
       enrollment_errors: ["Complete the machine details before generating configuration"],
       enrollment_open?: true
     )}
  end

  defp load_config_file(socket, rel) do
    config_source = socket.assigns.config_source

    config_file =
      if config_source.enabled? do
        case ConfigSource.read(config_source, rel) do
          {:ok, content, truncated?} ->
            %{
              rel: rel,
              truncated?: truncated?,
              error: nil,
              html: NixHighlighter.highlight(content)
            }

          {:error, reason} ->
            %{
              rel: rel,
              truncated?: false,
              error: "Could not read #{rel}: #{inspect(reason)}",
              html: ""
            }
        end
      end

    assign(socket, config_file: config_file, config_modal_open?: false)
  end

  defp state(nil), do: {"loading", "Loading"}

  defp state(snapshot) do
    summary = Map.get(snapshot, :summary, %{})
    drift = Map.get(snapshot, :drift, %{})

    cond do
      Map.get(snapshot, :stale?, false) -> {"stale", "Stale"}
      Map.get(summary, :live_nodes, 0) == 0 -> {"degraded", "Degraded"}
      Map.get(drift, :config_consistent?) == false -> {"degraded", "Degraded"}
      Map.get(snapshot, :errors, []) != [] -> {"degraded", "Degraded"}
      positive_count?(summary, :degraded_services) -> {"degraded", "Degraded"}
      positive_count?(summary, :awaiting_heal_services) -> {"degraded", "Degraded"}
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

  defp percent_of_100(value) when is_number(value), do: "#{Format.percent(value)} / 100%"
  defp percent_of_100(_), do: "unknown"

  # Cluster memory is reported in absolute GiB, not as a ratio of host totals.
  defp memory_usage_label(snapshot) do
    used = metric(snapshot, :memory, :used)
    total = metric(snapshot, :memory, :total)

    if is_number(used) and is_number(total) and total > 0 do
      "#{gib(used)} GiB / #{gib(total)} GiB"
    else
      "unknown"
    end
  end

  defp gib(value) do
    value
    |> Kernel./(1_073_741_824)
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp config_group_id(label) do
    slug =
      label
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    "map-config-group-#{slug}"
  end

  defp consistency_tone(snapshot) do
    case get_in(snapshot || %{}, [:drift, :config_consistent?]) do
      true -> "good"
      false -> "bad"
      _ -> "neutral"
    end
  end

  defp snapshot_state(snapshot), do: state(snapshot)

  defp snapshot_state(snapshot, true) when is_map(snapshot) and not snapshot.stale? do
    {tone, label} = state(snapshot)
    {if(tone == "healthy", do: "fresh", else: tone), "Fresh · #{label}"}
  end

  defp snapshot_state(snapshot, _just_refreshed), do: snapshot_state(snapshot)
  defp state_tone({tone, _label}), do: tone
  defp state_label({_tone, label}), do: label

  defp positive_count?(summary, key) do
    case Map.get(summary, key, 0) do
      value when is_number(value) and value > 0 -> true
      _ -> false
    end
  end

  defp summary_tone(:configured_nodes, _counts), do: "neutral"
  defp summary_tone(:services, _counts), do: "neutral"

  defp summary_tone(:live_nodes, counts),
    do: if(positive_count?(counts, :live_nodes), do: "good", else: "bad")

  defp summary_tone(:running_services, counts) do
    services = Map.get(counts, :services, 0)
    running = Map.get(counts, :running_services, 0)

    cond do
      not is_number(services) or services == 0 -> "neutral"
      is_number(running) and running >= services -> "good"
      is_number(running) and running > 0 -> "warn"
      true -> "bad"
    end
  end

  defp summary_tone(key, counts) when key in [:degraded_services, :awaiting_heal_services],
    do: if(positive_count?(counts, key), do: "bad", else: "good")

  defp machine_params(snapshot) do
    %{
      "hostname" => "",
      "deploy_host" => "",
      "nixos_configuration" => "",
      "firewall_interface" => "",
      "peers" => snapshot |> peer_names() |> Enum.join("\n")
    }
  end

  defp peer_names(snapshot) do
    snapshot = snapshot || %{}

    snapshot
    |> Map.get(:nodes, [])
    |> Enum.map(&Map.get(&1, :name))
    |> Enum.filter(&(is_binary(&1) and &1 != "unknown"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp configured_service_ports(source, snapshot) do
    snapshot = snapshot || %{}

    names =
      snapshot
      |> Map.get(:services, [])
      |> Enum.map(&Map.get(&1, :name))
      |> Enum.filter(&is_binary/1)

    ConfigSource.service_ports(source, names)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell id="dashboard" current_path="/" map_page={true}>
      <div class="map-screen">
        <aside id="map-sidebar-left" class="map-sidebar map-sidebar--left" phx-hook="MapSidebar" data-map-sidebar data-map-sidebar-side="left" aria-label="Cluster details">
          <div class="map-sidebar__header">
            <div>
              <p class="eyebrow">NIX-SWARM / TOPOLOGY</p>
              <h1 id="network-map-title">Cluster map</h1>
              <p id="network-map-description" class="map-sidebar__hint">Drag cards to arrange the topology.</p>
              <.status_badge label={state_label(snapshot_state(@snapshot, @just_refreshed?))} tone={state_tone(snapshot_state(@snapshot, @just_refreshed?))} />
            </div>
            <button
              type="button"
              class="btn btn-sm btn-ghost map-sidebar__toggle"
              data-map-sidebar-toggle="left"
              aria-expanded="true"
              aria-controls="map-sidebar-content"
            >
              Hide
            </button>
          </div>

          <div id="map-sidebar-content" class="map-sidebar__content">
            <%= if is_nil(@snapshot) do %>
              <section class="empty-state" aria-live="polite">
                <h2>Loading cluster status</h2>
                <p>The shared query broker is waiting for the first bounded snapshot.</p>
              </section>
            <% else %>
              <% counts = summary(@snapshot) %>
              <section class="map-summary" aria-label="Cluster summary">
                <.summary_card label="Configured nodes" value={Map.get(counts, :configured_nodes, 0)} tone={summary_tone(:configured_nodes, counts)} />
                <.summary_card label="Live nodes" value={Map.get(counts, :live_nodes, 0)} tone={summary_tone(:live_nodes, counts)} />
                <.summary_card label="Services" value={Map.get(counts, :services, 0)} tone={summary_tone(:services, counts)} />
                <.summary_card label="Running services" value={Map.get(counts, :running_services, 0)} tone={summary_tone(:running_services, counts)} />
                <.summary_card label="Degraded services" value={Map.get(counts, :degraded_services, 0)} tone={summary_tone(:degraded_services, counts)} />
                <.summary_card label="Awaiting heal" value={Map.get(counts, :awaiting_heal_services, 0)} tone={summary_tone(:awaiting_heal_services, counts)} />
              </section>

              <section class="map-legend map-sidebar__legend" aria-label="Map legend">
                <span><i class="legend-dot legend-dot--live" aria-hidden="true"></i>Live</span>
                <span><i class="legend-dot legend-dot--degraded" aria-hidden="true"></i>Attention</span>
                <span><i class="legend-dot legend-dot--unplaced" aria-hidden="true"></i>Unplaced</span>
              </section>

              <section class="map-meta" aria-label="Snapshot details">
                <div><span>Queried node</span><strong><%= @snapshot.queried_node %></strong></div>
                <div><span>Last refresh</span><strong><%= refresh_label(@snapshot) %></strong></div>
                <div><span>Broker interval</span><strong><%= Format.duration_ms(@broker_status.interval_ms) %></strong></div>
                <div><span>CPU</span><strong><%= percent_of_100(metric(@snapshot, :cpu, :pct)) %></strong></div>
                <div><span>Memory</span><strong><%= memory_usage_label(@snapshot) %></strong></div>
                <div><span>Network received</span><strong><%= metric_label(metric(@snapshot, :network, :received), :bytes) %></strong></div>
                <div class={["map-meta__consistency", "map-meta__consistency--#{consistency_tone(@snapshot)}"]}><span>Config consistent</span><strong><%= config_label(@snapshot) %></strong></div>
              </section>

              <%= if Map.get(@snapshot, :stale?, false) do %>
                <section class="notice notice--stale" role="alert">
                  <strong>Stale data</strong>
                  <span>Showing the last good snapshot; the latest query failed.</span>
                </section>
              <% end %>

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

          </div>
          <button
            type="button"
            class="map-sidebar__resize-handle"
            data-sidebar-resize="left"
            role="separator"
            aria-orientation="vertical"
            aria-label="Resize cluster details sidebar"
          ></button>
        </aside>

        <aside id="map-sidebar-right" class="map-sidebar map-sidebar--right" phx-hook="MapSidebar" data-map-sidebar data-map-sidebar-side="right" aria-label="NixOS tools">
          <div class="map-sidebar__header">
            <div>
              <p class="eyebrow">NIXOS / ENROLLMENT</p>
              <h2>NixOS tools</h2>
              <p class="map-sidebar__hint">Add machines and inspect desired state.</p>
            </div>
            <button
              type="button"
              class="btn btn-sm btn-ghost map-sidebar__toggle"
              data-map-sidebar-toggle="right"
              aria-expanded="true"
              aria-controls="map-right-sidebar-content"
            >
              Hide
            </button>
          </div>

          <div id="map-right-sidebar-content" class="map-sidebar__content">
            <section class="machine-enrollment-guide" aria-label="Add a new machine">
              <div class="machine-enrollment-guide__header">
                <div>
                  <p class="eyebrow">NIXOS / ENROLLMENT</p>
                  <h2>Add a new machine</h2>
                </div>
                <button
                  type="button"
                  class="btn btn-primary btn-sm"
                  phx-click="open_machine_enrollment"
                >
                  Add New Machine
                </button>
              </div>
            </section>

            <section class="map-file-output" aria-label="Selected Nix file" data-file-output>
              <%= cond do %>
                <% not @config_source.enabled? -> %>
                  <p class="map-config__empty">
                    No source is connected. Start the web process with
                    <code>NIX_SWARM_CONFIG_SOURCE=/path/to/nix-swarm</code> to read its read-only <code>.nix</code> files here.
                  </p>
                <% @config_notice -> %>
                  <p class="map-config__empty" role="status" data-file-output-empty><%= @config_notice %></p>
                <% @config_file -> %>
                  <div class="map-config__viewer" data-config-viewer>
                    <div class="map-config__viewer-head">
                      <strong class="map-config__viewer-name"><%= Path.basename(@config_file.rel) %></strong>
                      <span class="map-config__viewer-actions">
                        <button type="button" class="btn btn-xs btn-ghost" data-copy-target="map-config-viewer-code">Copy</button>
                        <button type="button" class="btn btn-xs btn-ghost" phx-click="open_config_modal">Pop out</button>
                        <button type="button" class="btn btn-xs btn-ghost" phx-click="close_config_file">Close</button>
                      </span>
                    </div>

                    <%= if @config_file.error do %>
                      <p class="map-config__error" role="alert"><%= @config_file.error %></p>
                    <% else %>
                      <pre class="map-config__code" tabindex="0"><code id="map-config-viewer-code" data-config-code><%= Phoenix.HTML.raw(@config_file.html) %></code></pre>
                      <%= if @config_file.truncated? do %>
                        <p class="map-config__truncated">
                          Showing the first <%= Format.bytes(NixSwarmWeb.ConfigSource.max_bytes()) %>; the file is larger and is read on demand only.
                        </p>
                      <% end %>
                    <% end %>
                  </div>
                <% true -> %>
                  <p class="map-config__empty" role="status" data-file-output-empty>
                    Select a machine or service on the map, or a file under Config source, to read its <code>.nix</code> file here.
                  </p>
              <% end %>
            </section>

            <section class="map-config" aria-label="Nix source files" data-config-section>
              <%= if @config_source.enabled? do %>
                <div class="map-config__controls">
                  <%= if @config_source.root do %>
                    <p class="map-config__root"><%= @config_source.root %></p>
                  <% end %>
                  <button
                    type="button"
                    class="btn btn-sm btn-ghost map-config__toggle"
                    phx-click="toggle_config_section"
                    aria-expanded={@config_open?}
                    aria-controls="map-config-files"
                  >
                    <%= if @config_open?, do: "Hide files", else: "Show files" %>
                  </button>
                </div>
              <% end %>

              <%= if not @config_source.enabled? do %>
                <p class="map-config__empty">
                  No source is connected. Start the web process with
                  <code>NIX_SWARM_CONFIG_SOURCE=/path/to/nix-swarm</code> to browse its read-only <code>.nix</code> files here.
                </p>
              <% else %>
                <%= if @config_open? do %>
                  <%= if @config_source.file_count == 0 do %>
                    <p class="map-config__empty">No <code>.nix</code> files were found under the configured source.</p>
                  <% else %>
                    <div id="map-config-files" class="map-config__groups">
                      <%= for group <- @config_source.groups do %>
                        <% collapsed = MapSet.member?(@config_groups_collapsed, group.label) %>
                        <div class="map-config__group" data-config-group={group.label}>
                          <h3 class="map-config__group-title">
                            <button
                              type="button"
                              class="map-config__group-toggle"
                              data-config-group-toggle={group.label}
                              phx-click="toggle_config_group"
                              phx-value-group={group.label}
                              aria-expanded={if collapsed, do: "false", else: "true"}
                              aria-controls={config_group_id(group.label)}
                            >
                              <span class="map-config__group-caret" aria-hidden="true"><%= if collapsed, do: "▸", else: "▾" %></span>
                              <span class="map-config__group-label"><%= group.label %></span>
                              <span class="map-config__group-count"><%= length(group.files) %></span>
                            </button>
                          </h3>
                          <ul id={config_group_id(group.label)} class="map-config__files" hidden={collapsed}>
                            <%= for file <- group.files do %>
                              <li>
                                <button
                                  type="button"
                                  class={["map-config__file", if(@config_file != nil and @config_file.rel == file.rel, do: "is-active", else: "")]}
                                  data-config-file
                                  phx-click="open_config_file"
                                  phx-value-rel={file.rel}
                                >
                                  <span class="map-config__file-name"><%= Path.basename(file.rel) %></span>
                                  <span class="map-config__file-size"><%= Format.bytes(file.size) %></span>
                                </button>
                              </li>
                            <% end %>
                          </ul>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                <% end %>
              <% end %>
            </section>
          </div>
          <button
            type="button"
            class="map-sidebar__resize-handle"
            data-sidebar-resize="right"
            role="separator"
            aria-orientation="vertical"
            aria-label="Resize NixOS tools sidebar"
          ></button>
        </aside>

        <NetworkMapComponent.network_map snapshot={@snapshot || %{}} service_ports={@service_ports} />

        <%= if @config_modal_open? and @config_file do %>
          <div class="config-modal" data-config-modal role="dialog" aria-modal="true" aria-labelledby="config-modal-title">
            <section class="config-modal__panel">
              <header class="config-modal__header">
                <div>
                  <p class="eyebrow">NIX / CONFIGURATION</p>
                  <h2 id="config-modal-title"><%= Path.basename(@config_file.rel) %></h2>
                </div>
                <button type="button" class="btn btn-sm btn-ghost" phx-click="close_config_modal" aria-label="Close Nix configuration">Close</button>
              </header>
              <div class="config-modal__body">
                <div class="config-modal__actions">
                  <span>Read-only source view</span>
                  <button type="button" class="btn btn-sm btn-primary" data-copy-target="map-config-modal-code">Copy configuration</button>
                </div>
                <%= if @config_file.error do %>
                  <p class="map-config__error" role="alert"><%= @config_file.error %></p>
                <% else %>
                  <pre class="config-modal__code" tabindex="0"><code id="map-config-modal-code"><%= Phoenix.HTML.raw(@config_file.html) %></code></pre>
                <% end %>
              </div>
            </section>
          </div>
        <% end %>

        <%= if @enrollment_open? do %>
          <div class="machine-enrollment-modal" role="dialog" aria-modal="true" aria-labelledby="machine-enrollment-title">
            <section class="machine-enrollment-modal__panel">
              <header class="machine-enrollment-modal__header">
                <div>
                  <p class="eyebrow">NIXOS / ENROLLMENT</p>
                  <h2 id="machine-enrollment-title">Generate machine configuration</h2>
                </div>
                <button type="button" class="btn btn-sm btn-ghost" phx-click="close_machine_enrollment" aria-label="Close machine enrollment">Close</button>
              </header>

              <%= if @enrollment do %>
                <div class="machine-enrollment-output">
                  <div class="notice notice--info">
                    <strong>Review before copying.</strong>
                    <span>No cookie or deployment credential is included.</span>
                  </div>

                  <div class="machine-enrollment-output__heading">
                    <h3>Machine configuration</h3>
                    <span><%= @enrollment.filename %></span>
                  </div>
                  <textarea id="machine-config-output" class="machine-enrollment-output__code" rows="18" readonly aria-label="Generated machine configuration"><%= @enrollment.machine_config %></textarea>
                  <button type="button" class="btn btn-sm btn-primary" data-copy-target="machine-config-output">Copy machine file</button>

                  <div class="machine-enrollment-output__heading">
                    <h3>Central inventory snippet</h3>
                    <span>Paste into <code>services.nix-swarm.nodes</code></span>
                  </div>
                  <textarea id="machine-inventory-output" class="machine-enrollment-output__code" rows="8" readonly aria-label="Generated central inventory snippet"><%= @enrollment.inventory_snippet %></textarea>
                  <button type="button" class="btn btn-sm btn-primary" data-copy-target="machine-inventory-output">Copy inventory snippet</button>

                  <section class="machine-enrollment-output__next-steps" aria-label="Next steps">
                    <h3>Next steps</h3>
                    <ol>
                      <li>Copy the machine file to the target and combine it with its real hardware configuration.</li>
                      <li>Paste the inventory snippet into the shared cluster module and add the node to every peer list.</li>
                      <li>Run <code>nix flake lock</code>, <code>nix-swarm cluster plan --source .</code>, then <code>nix-swarm cluster apply --source . --yes</code>.</li>
                      <li>Verify with <code>nix-swarm cluster doctor --target <%= @enrollment.node_name %></code> and <code>nix-swarm cluster status --target <%= @enrollment.node_name %></code>.</li>
                    </ol>
                  </section>
                </div>
              <% else %>
                <p class="machine-enrollment-modal__intro">
                  Enter the target's deployment details. The node name is derived as <code>nix-swarm@&lt;hostname&gt;</code>.
                </p>

                <section class="machine-enrollment-modal__instructions" aria-label="Machine enrollment instructions">
                  <h3>Before you generate the file</h3>
                  <ol class="machine-enrollment-guide__steps">
                    <li><strong>Prepare the target machine.</strong> It must already run NixOS with verified SSH access and a trusted private-network path to the cluster.</li>
                    <li><strong>Copy the generated module.</strong> Keep the target's real hardware configuration and adjust the import paths if your flake layout differs.</li>
                    <li><strong>Update desired state.</strong> Add the generated inventory entry and complete peer list to the shared cluster module and export the evaluated manifest.</li>
                    <li><strong>Review and apply.</strong> Run <code>nix-swarm cluster plan --source .</code>, then <code>nix-swarm cluster apply --source . --yes</code>.</li>
                    <li><strong>Verify.</strong> Use <code>cluster doctor</code> and <code>cluster status</code> for the new node.</li>
                  </ol>
                  <p class="machine-enrollment-guide__note">
                    The generated file never contains the cluster cookie. Normal <code>cluster apply</code> enrolls a missing cookie over verified SSH; it does not create a mutable registration record.
                  </p>
                </section>

                <%= if @enrollment_errors != [] do %>
                  <div class="notice notice--error" role="alert">
                    <strong>Check these values:</strong>
                    <ul>
                      <%= for error <- @enrollment_errors do %>
                        <li><%= error %></li>
                      <% end %>
                    </ul>
                  </div>
                <% end %>

                <form id="machine-enrollment-form" phx-submit="generate_machine_config">
                  <div class="machine-enrollment-form__grid">
                    <label>
                      Hostname
                      <input class="input input-bordered" type="text" name="machine[hostname]" value={Map.get(@machine_params, "hostname", "")} placeholder="node-b" maxlength="253" autocomplete="off" required />
                    </label>
                    <label>
                      SSH deploy host
                      <input class="input input-bordered" type="text" name="machine[deploy_host]" value={Map.get(@machine_params, "deploy_host", "")} placeholder="root@node-b" maxlength="320" autocomplete="off" required />
                    </label>
                    <label>
                      NixOS configuration
                      <input class="input input-bordered" type="text" name="machine[nixos_configuration]" value={Map.get(@machine_params, "nixos_configuration", "")} placeholder="node-b" maxlength="128" autocomplete="off" required />
                    </label>
                    <label>
                      Private firewall interface
                      <input class="input input-bordered" type="text" name="machine[firewall_interface]" value={Map.get(@machine_params, "firewall_interface", "")} placeholder="wg0" maxlength="128" autocomplete="off" required />
                    </label>
                  </div>
                  <label class="machine-enrollment-form__peers">
                    Existing peer node names
                    <textarea class="textarea textarea-bordered" name="machine[peers]" rows="5" maxlength="8192" placeholder="nix-swarm@node-a&#10;nix-swarm@node-b"><%= Map.get(@machine_params, "peers", "") %></textarea>
                    <span class="machine-enrollment-form__help">One distributed Erlang node name per line. The new node is added automatically.</span>
                  </label>
                  <div class="machine-enrollment-form__actions">
                    <button type="button" class="btn btn-ghost" phx-click="close_machine_enrollment">Cancel</button>
                    <button type="submit" class="btn btn-primary">Generate machine configuration</button>
                  </div>
                </form>
              <% end %>
            </section>
          </div>
        <% end %>
      </div>
    </.app_shell>
    """
  end
end
