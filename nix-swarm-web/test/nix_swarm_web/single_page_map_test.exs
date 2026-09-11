defmodule NixSwarmWeb.SinglePageMapTest do
  use NixSwarmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias NixSwarmWeb.{DashboardLive, NetworkMapComponent, SnapshotFixture}

  @css Path.expand("../../assets/css/app.css", __DIR__)
  @js Path.expand("../../assets/js/app.js", __DIR__)

  setup do
    context = SnapshotFixture.broker_setup(__MODULE__)
    on_exit(fn -> SnapshotFixture.stop(context) end)
    context
  end

  test "the dashboard is a single interactive cluster map", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, DashboardLive)

    assert html =~ ~s(id="cluster-map")
    assert html =~ ~s(phx-hook="NetworkMap")
    assert html =~ "Cluster map"
    assert html =~ "Drag cards to arrange"
    assert html =~ ~s(data-map-action="zoom-in")
    assert html =~ ~s(data-map-action="zoom-out")
    assert html =~ ~s(data-map-action="fit")
    assert html =~ ~s(data-map-action="reset")
    assert html =~ ~s(data-map-inspector)
    assert html =~ ~s(data-map-item-kind="node")
    assert html =~ ~s(data-map-item-kind="service")
    assert html =~ ~s(class="map-screen")
    assert html =~ ~s(data-map-sidebar-side="left")
    assert html =~ ~s(data-map-sidebar-side="right")
    assert html =~ ~s(data-map-sidebar-toggle="left")
    assert html =~ ~s(data-map-sidebar-toggle="right")
    assert html =~ ~s(data-sidebar-resize="left")
    assert html =~ ~s(data-sidebar-resize="right")
    assert html =~ "NIXOS / ENROLLMENT"
    assert html =~ ~s(class="map-inspector is-empty")
    assert html =~ "api@0.service"
    refute html =~ ~s(class="app-nav")
    refute html =~ "Cluster dashboard"
  end

  test "map cards show node and service resource facts", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, DashboardLive)

    assert html =~ "IP 10.0.0.1"
    assert html =~ "Ports 4369"
    assert html =~ "CPU 50.0%"
    assert html =~ "RAM 50 B / 100 B"
    assert html =~ "CPU 3.0%"
    assert html =~ "RAM 9 B"
    assert html =~ "Port 8080"
  end

  test "renders proxy and a Hubble-style traffic flow panel", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, DashboardLive)

    assert html =~ ~s(data-map-item-kind="proxy")
    assert html =~ "Nix-Swarm proxy"
    assert html =~ "Traffic flows"
    assert html =~ "Declared route"
    assert html =~ ~s(data-map-flow-source="proxy")
    assert html =~ ~s(data-map-flow-target="node-b@cluster")
    assert html =~ "Layer 4 counters"
  end

  test "renders observed network rates for machines and services" do
    snapshot =
      SnapshotFixture.snapshot()
      |> put_in([:metrics, :rates], %{
        node_network: %{
          "node-a@cluster" => %{received: 4096, transmitted: 2048, total: 6144, rate: 3072.0}
        },
        service_network: %{
          "api|0|api@0.service" => %{received: 1024, transmitted: 512, total: 1536, rate: 768.0}
        }
      })

    html = render_component(&NetworkMapComponent.network_map/1, snapshot: snapshot)

    assert html =~ "Rx 4 KiB/s · Tx 2 KiB/s"
    assert html =~ "Traffic Rx 1 KiB/s · Tx 512 B/s"
    assert html =~ "Observed"
  end

  test "machines are arranged in multiple columns by default", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, DashboardLive)

    assert html =~ ~r{data-map-item-key="node-a@cluster"[^>]*data-map-x="80"}
    assert html =~ ~r{data-map-item-key="node-b@cluster"[^>]*data-map-x="948"}
    assert html =~ ~r{data-map-item-key="node-c@cluster"[^>]*data-map-x="80"}
    assert html =~ ~s(data-map-width="1848")
  end

  test "machine cards show their reported open ports", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, DashboardLive)

    assert html =~ ~s(class="map-card-detail">Ports 4369</text>)
  end

  test "machine and service cards put the IP on its own line", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, DashboardLive)

    ip_line = ~s(class="map-card-subtitle">IP 10.0.0.1</text>)

    # Once for the owning machine card and once for its placed service card.
    assert length(String.split(html, ip_line)) == 3
    refute html =~ ~s(class="map-card-subtitle">IP 10.0.0.1 · Ports)
  end

  test "service cards carry the port but no status word", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, DashboardLive)

    assert html =~
             ~s(data-map-detail="CPU 3.0% · RAM unknown · Port 8080 · Owned by node-a@cluster")

    assert html =~ ~s(class="map-card-detail map-card-detail--secondary">Port 8080</text>)
  end

  test "service cards use configured ports when runtime payload omits them" do
    html =
      render_component(&NetworkMapComponent.network_map/1,
        snapshot: SnapshotFixture.snapshot(),
        service_ports: %{"worker" => [3123]}
      )

    assert html =~ ~s(class="map-card-detail map-card-detail--secondary">Port 3123</text>)
  end

  test "summary cards use color to distinguish healthy and issue counts", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, DashboardLive)

    assert html =~ ~s(class="card card-border summary-card summary-card--neutral")
    assert html =~ ~s(class="card card-border summary-card summary-card--good")
    assert html =~ ~s(class="card card-border summary-card summary-card--bad")
  end

  test "a machine with no running service still renders its card" do
    html =
      render_component(&NetworkMapComponent.network_map/1,
        snapshot: %{
          nodes: [
            %{
              name: "swarm@10.9.9.9",
              status: "unknown",
              availability: "active",
              version: "v1",
              network_info: %{ips: [], ports: []},
              metrics: %{},
              services: []
            }
          ],
          services: [],
          metrics: %{}
        }
      )

    assert html =~ ~s(data-map-item-kind="node")
    assert html =~ "swarm@10.9.9.9"
    # The name@host identity is the IP source when the agent reports no IPs.
    assert html =~ ~s(class="map-card-subtitle">IP 10.9.9.9</text>)
    assert html =~ "No owned services"
    refute html =~ "No cluster items are currently reported."
  end

  test "intentional offline nodes render with the offline class" do
    html =
      render_component(&NetworkMapComponent.network_map/1,
        snapshot: %{
          nodes: [
            %{
              name: "swarm@10.9.9.8",
              status: "unknown",
              availability: "maintenance",
              version: "v1",
              network_info: %{ips: [], ports: []},
              metrics: %{},
              services: []
            }
          ],
          services: [],
          metrics: %{}
        }
      )

    assert html =~ "map-node is-offline"
  end

  test "the map grid is a canvas background that covers the whole map area" do
    css = File.read!(@css)

    assert css =~ "--map-grid-size: 32px;"

    assert css =~
             "background-image: linear-gradient(to right, var(--map-grid-line) 1px, transparent 1px)"

    assert css =~ "background-size: var(--map-grid-size) var(--map-grid-size);"
    refute css =~ ".map-grid-line"
  end

  test "status colours are red for down, yellow for issues, gray for intentional offline" do
    css = File.read!(@css)

    assert css =~ ".map-item.is-down > .map-status-dot { fill: var(--color-error); }"

    assert css =~
             ".map-item.is-degraded > .map-status-dot, .map-item.is-unplaced > .map-status-dot { fill: var(--color-warning); }"

    assert css =~
             ".map-item.is-offline > .map-status-dot { fill: color-mix(in oklab, var(--color-base-content) 45%, transparent); }"
  end

  test "status classes drive the map colours", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, DashboardLive)

    # node-a/node-b are up -> green, node-c is unreachable -> red,
    # the api@1 slot has no owner -> yellow (attention).
    assert html =~ "map-node is-live"
    assert html =~ "map-node is-down"
    assert html =~ "map-service is-unplaced"
  end

  test "the sidebar reports cluster memory in GiB rather than a ratio", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, DashboardLive)

    assert html =~ ~r{<span>Memory</span><strong>\d+\.\d GiB / \d+\.\d GiB</strong>}
    refute html =~ ~r{<span>Memory</span><strong>[^<]*%}
  end

  test "map items expose semantic selection and an accessible fallback", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, DashboardLive)

    assert html =~ ~s(role="button")
    assert html =~ ~s(tabindex="0")
    assert html =~ ~s(data-map-machine="node-a@cluster")
    refute html =~ ~s(data-map-edge-node="node-a@cluster")
    assert html =~ "Map data table"
    assert html =~ "Click a node or service to inspect it."
  end

  test "the browser hook supports pan, zoom, drag, fit, reset, and selection" do
    js = File.read!(@js)

    assert js =~ "NetworkMap"
    assert js =~ "data-map-action"
    assert js =~ "pointerdown"
    assert js =~ "pointermove"
    assert js =~ "wheel"
    assert js =~ "fitToContent"
    assert js =~ "setDefaultView"
    assert js =~ "const mapBaseScale = 1.29"
    assert js =~ "4.3x larger"
    assert js =~ "sidebarToggleHandler = () => this.applyTransform()"
    refute js =~ "sidebarToggleHandler = () => this.fitToContent()"
    assert js =~ "renderScale"
    assert js =~ "selectItem"
    refute js =~ "updateEdges"
    assert js =~ "mapBoxWidth"
    assert js =~ "mapBoxHeight"
    assert js =~ "is-empty"
    assert js =~ "getScreenCTM"
    assert js =~ "contentPoint.x * this.renderScale()"
    assert js =~ "data-copy-target"
    assert js =~ "data-sidebar-resize"
    assert js =~ "nix-swarm:sidebar-width"
    assert js =~ "applySidebarWidths"
    assert js =~ "const MapSidebar"
    assert js =~ "updated()"
    assert js =~ "resolveMachinePosition"
    assert js =~ "machineOverlaps"
    assert js =~ "updateFlowEdges"
    assert js =~ "flowPoint"
    assert js =~ "this.pointer.requested"
    assert js =~ "this.pointer.requested,\n        this.pointer.origin"
    assert js =~ "translate(${position.x} ${position.y})"
    refute js =~ "position.x - x"
  end

  test "network traffic styling keeps declared and observed flows distinct" do
    css = File.read!(@css)

    assert css =~ ".map-flow-edge"
    assert css =~ ".map-flow-edge--declared"
    assert css =~ ".map-flow-row--observed"
    assert css =~ ".map-flow-panel"
  end

  test "service information has increased line spacing" do
    css = File.read!(@css)
    assert css =~ ".map-card-detail--secondary { fill:"

    html =
      render_component(&NetworkMapComponent.network_map/1, snapshot: SnapshotFixture.snapshot())

    assert html =~ ~s(y="250" class="map-card-subtitle")
    assert html =~ ~s(y="278" class="map-card-detail")
    assert html =~ ~s(y="302" class="map-card-detail")
    assert html =~ ~s(y="326" class="map-card-detail map-card-detail--secondary")
  end

  test "collapsed sidebars persist through updates and remain compact" do
    css = File.read!(@css)
    js = File.read!(@js)

    assert css =~
             ".map-sidebar.is-collapsed { width: auto; bottom: auto; height: fit-content; max-height: none; }"

    assert css =~ ".map-sidebar.is-collapsed .map-sidebar__resize-handle { display: none; }"
    assert js =~ "sidebarVisibilityStorageKey"
    assert js =~ "applySidebarVisibility"
    assert js =~ "window.localStorage.setItem(\n    `${sidebarVisibilityStorageKey}:${side}`"
  end

  test "mobile map overlays reserve separate control bands" do
    css = File.read!(@css)
    mobile_rules = css |> String.split("@media (max-width: 600px)", parts: 2) |> List.last()

    assert mobile_rules =~
             ".map-sidebar--left { top: 4.45rem; }"

    assert mobile_rules =~
             ".map-sidebar--right { top: calc(4.45rem + max(10rem, min(32vh, 15rem)) + .75rem); right: .7rem; bottom: auto; left: auto; max-height: max(10rem, min(32vh, 15rem)); }"

    assert mobile_rules =~
             ".map-toolbar { top: auto; right: .7rem; bottom: .7rem; left: .7rem; transform: none; }"

    assert mobile_rules =~
             ".map-inspector { right: .7rem; bottom: 4.7rem; width: min(17rem, calc(100vw - 1.4rem)); max-height: 30vh; }"

    assert mobile_rules =~ ".map-flow-row { grid-template-columns: 1fr; gap: .2rem; }"

    assert mobile_rules =~
             ".map-screen:has(.map-sidebar--right:not(.is-collapsed)) .map-flow-panel { max-height: 16vh; }"
  end

  test "desktop sidebars use the expanded width and reach the lower viewport edge" do
    css = File.read!(@css)
    js = File.read!(@js)

    assert css =~ "--map-sidebar-max-width: 48.75rem;"
    assert css =~ "calc(50vw - 2rem)"
    assert css =~ "bottom: 1.25rem;"
    assert css =~ "max-height: none;"
    assert js =~ "window.innerWidth > 600"
    assert js =~ "Math.min(780, sidebarViewportWidth())"
  end

  test "sidebar summary and meta boxes share one narrow column track" do
    css = File.read!(@css)

    assert css =~
             ".map-sidebar .map-summary { grid-template-columns: repeat(3, minmax(0, 1fr));"

    assert css =~ ".map-sidebar .map-meta { grid-template-columns: repeat(3, minmax(0, 1fr));"
  end

  test "left sidebar boxes use the same treatment as right sidebar panels" do
    css = File.read!(@css)

    assert css =~
             ".map-sidebar .summary-card, .map-sidebar .map-meta > div { border: 1px solid var(--color-base-300); border-radius: var(--radius-field); background: color-mix(in oklab, var(--color-primary) 5%, var(--color-base-100)); }"

    assert css =~
             ".map-sidebar .summary-card, .map-sidebar .map-meta > div { border: 1px solid var(--color-base-300);"
  end

  test "sidebar explains machine enrollment and generates safe configuration", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, DashboardLive)

    assert html =~ "Add New Machine"
    refute html =~ "Prepare the target machine"
    refute html =~ "cluster plan"
    refute html =~ "machine-node-d.nix"

    html = render_click(view, "open_machine_enrollment")
    assert html =~ ~s(role="dialog")
    assert html =~ "Generate machine configuration"
    assert html =~ "Prepare the target machine"
    assert html =~ "cluster plan"

    html =
      view
      |> element("form[phx-submit='generate_machine_config']")
      |> render_submit(%{
        "machine" => %{
          "hostname" => "node-d",
          "deploy_host" => "root@node-d",
          "nixos_configuration" => "node-d",
          "firewall_interface" => "wg0",
          "peers" => "node-a@cluster\nnode-b@cluster"
        }
      })

    assert html =~ "machine-node-d.nix"
    assert html =~ ~s(nodeName = &quot;nix-swarm@node-d&quot;;)
    assert html =~ "Central inventory snippet"
    assert html =~ "Copy"
  end
end
