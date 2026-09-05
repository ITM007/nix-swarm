defmodule NixSwarmWeb.NetworkLiveTest do
  use NixSwarmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias NixSwarmWeb.{NetworkMapComponent, NetworkLive, SnapshotFixture}

  setup do
    context = SnapshotFixture.broker_setup(__MODULE__)
    on_exit(fn -> SnapshotFixture.stop(context) end)
    context
  end

  test "renders deterministic accessible SVG nodes, edges, and table fallback", %{
    snapshot: snapshot
  } do
    html =
      Phoenix.LiveViewTest.render_component(&NetworkMapComponent.network_map/1,
        snapshot: snapshot
      )

    assert html =~ ~s(role="img")
    assert html =~ "Network and ownership map"
    assert html =~ "node-a@cluster"
    assert html =~ "api@0.service"
    assert html =~ "Unplaced"
    assert html =~ ~s(href="/nodes/bm9kZS1hQGNsdXN0ZXI")
    assert html =~ ~s(href="/services/YXBp")
    assert html =~ "aria-label=\"api slot 0 owned by node-a@cluster\""
    assert html =~ "<table"
  end

  test "keeps layout order stable for zero, one, and many nodes" do
    empty = NixSwarmWeb.ClusterSnapshot.empty(~U[2026-09-05 12:00:00Z])

    html =
      Phoenix.LiveViewTest.render_component(&NetworkMapComponent.network_map/1, snapshot: empty)

    assert html =~ "No nodes are currently reported"

    nodes =
      Enum.map(["z@host", "a@host", "m@host"], fn name ->
        %{name: name, host: "host", status: "unknown", version: "unknown"}
      end)

    snapshot = %{empty | nodes: nodes, graph: %{nodes: nodes, ownership_edges: []}}

    html =
      Phoenix.LiveViewTest.render_component(&NetworkMapComponent.network_map/1,
        snapshot: snapshot
      )

    assert :binary.match(html, "a@host") < :binary.match(html, "m@host")
    assert :binary.match(html, "m@host") < :binary.match(html, "z@host")
  end

  test "renders stale and degraded state and updates from PubSub", %{conn: conn, pubsub: pubsub} do
    stale = %{
      SnapshotFixture.snapshot()
      | stale?: true,
        errors: [%{scope: "node", reason: "timeout"}]
    }

    NixSwarmWeb.QueryBroker.put_snapshot(NixSwarmWeb.QueryBroker.broker_name(), stale)
    {:ok, view, html} = live_isolated(conn, NetworkLive)
    assert html =~ "Stale"
    assert html =~ "Degraded"
    assert html =~ "timeout"

    fresh = %{stale | stale?: false, errors: []}
    Phoenix.PubSub.broadcast(pubsub, "cluster:snapshot", {:cluster_snapshot, fresh})
    assert render(view) =~ "Fresh"
  end
end
