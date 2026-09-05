defmodule NixSwarmWeb.NodeLiveTest do
  use NixSwarmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias NixSwarmWeb.{NodeIndexLive, NodeShowLive, SnapshotFixture}

  setup do
    context = SnapshotFixture.broker_setup(__MODULE__)
    on_exit(fn -> SnapshotFixture.stop(context) end)
    context
  end

  test "lists sorted nodes with health, version, resources, networking, and units", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, NodeIndexLive)

    assert html =~ "Nodes"
    assert :binary.match(html, "node-a@cluster") < :binary.match(html, "node-b@cluster")
    assert html =~ "node-c@cluster"
    assert html =~ "node_unreachable"
    assert html =~ "2.0.0+aaa"
    assert html =~ "10.0.0.1"
    assert html =~ "50%"
    assert html =~ "api@0.service"
    assert html =~ ~s(href="/nodes/bm9kZS1hQGNsdXN0ZXI")
  end

  test "shows only the current snapshot node and keeps unknown route params explicit", %{
    conn: conn
  } do
    {:ok, _view, html} =
      live_isolated(conn, NodeShowLive, session: %{"node" => "bm9kZS1hQGNsdXN0ZXI"})

    assert html =~ "node-a@cluster"
    assert html =~ "Owned units"
    assert html =~ "api@0.service"
    refute html =~ "node-b@cluster"

    {:ok, _view, unknown_html} =
      live_isolated(conn, NodeShowLive, session: %{"node" => "bm9kZS1ub3QtcmVhbA"})

    assert unknown_html =~ "Unknown node"
    assert unknown_html =~ "current snapshot"
  end

  test "loads bounded node logs only after an explicit event", %{conn: conn, broker: broker} do
    :sys.replace_state(broker, fn state ->
      %{state | query_fun: fn {:node_service_logs, node, 200} -> {:ok, ["node #{node} log"]} end}
    end)

    {:ok, view, html} =
      live_isolated(conn, NodeShowLive, session: %{"node" => "bm9kZS1hQGNsdXN0ZXI"})

    refute html =~ "node node-a@cluster log"
    assert render_click(view, "load_logs", %{"lines" => "200"}) =~ "node node-a@cluster log"
    assert render(view) =~ "Fetched"
    assert render(view) =~ "node-a@cluster"
  end
end
