defmodule NixSwarmWeb.ParityTest do
  use NixSwarmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias NixSwarmWeb.{
    DashboardLive,
    DriftLive,
    LogsLive,
    NetworkLive,
    NodeIndexLive,
    NodeShowLive,
    QueryBroker,
    ServiceIndexLive,
    ServiceShowLive,
    SnapshotFixture
  }

  setup do
    context = SnapshotFixture.broker_setup(__MODULE__)
    on_exit(fn -> SnapshotFixture.stop(context) end)
    context
  end

  test "status parity covers dashboard, network, nodes, services, and issues", %{conn: conn} do
    dashboard = live_html(conn, DashboardLive)
    assert dashboard =~ "Configured nodes"
    assert dashboard =~ "Live nodes"
    assert dashboard =~ "37.5%"
    assert dashboard =~ "Degraded services"

    network = live_html(conn, NetworkLive)
    assert network =~ "Node liveness"
    assert network =~ "10.0.0.1"
    assert network =~ "api@0.service"
    assert network =~ "Unplaced"

    nodes = live_html(conn, NodeIndexLive)
    assert nodes =~ "Configured and live machines"
    assert nodes =~ "2.0.0+aaa"
    assert nodes =~ "node_unreachable"
    assert nodes =~ "Owned units"

    node = live_html(conn, NodeShowLive, session: %{"node" => "bm9kZS1hQGNsdXN0ZXI"})
    assert node =~ "node-a@cluster"
    assert node =~ "Health and version"
    assert node =~ "Network"
    assert node =~ "api@0.service"

    services = live_html(conn, ServiceIndexLive)
    assert services =~ "Desired replicas"
    assert services =~ "api"
    assert services =~ "awaiting_heal"
    assert services =~ "auto_heal"

    service = live_html(conn, ServiceShowLive, session: %{"service" => "YXBp"})
    assert service =~ "Slots and ownership"
    assert service =~ "api@1.service"
    assert service =~ "Unplaced"
    assert service =~ "State contract"
  end

  test "drift parity distinguishes diagnostics and unknown consistency", %{conn: conn} do
    html = live_html(conn, DriftLive)

    for finding <- [
          "config digest mismatch",
          "Mixed release versions",
          "release_version",
          "unplaced_slot"
        ] do
      assert html =~ finding
    end

    unknown = SnapshotFixture.snapshot()

    unknown = %{
      unknown
      | drift: %{config_consistent?: nil, digests: %{}, diagnostics: [], versions: []}
    }

    QueryBroker.put_snapshot(QueryBroker.broker_name(), unknown)
    html = live_html(conn, DriftLive)
    assert html =~ "Unknown"
    refute html =~ "In sync"
  end

  test "logs parity exposes bounded scopes, literal search, filters, and navigation", %{
    conn: conn
  } do
    html = live_html(conn, LogsLive)

    assert html =~ "Cluster"
    assert html =~ "Node"
    assert html =~ "Service"
    assert html =~ "Lines (1–1000)"
    assert html =~ "Literal search"
    assert html =~ "Warnings/errors"
    assert html =~ "Previous match"
    assert html =~ "Next match"
    assert html =~ "refresh explicitly"
  end

  test "export parity serves all four in-memory download types", %{conn: conn} do
    for {path, content_type, body_fragment} <- [
          {"/exports/snapshot.json", "application/json", "node-a@cluster"},
          {"/exports/nodes.csv", "text/csv", "node-a@cluster"},
          {"/exports/services.csv", "text/csv", "api"},
          {"/exports/logs.txt?scope=cluster&target=node-a%40cluster&lines=20", "text/plain", ""}
        ] do
      response = conn |> Phoenix.ConnTest.recycle() |> get(path)
      assert response.status == 200
      assert get_resp_header(response, "content-type") |> hd() =~ content_type
      assert response(response, 200) =~ body_fragment
    end
  end

  defp live_html(conn, module, opts \\ []) do
    {:ok, _view, html} = live_isolated(conn, module, opts)
    html
  end
end
