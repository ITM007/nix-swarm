defmodule NixSwarmWeb.ServiceLiveTest do
  use NixSwarmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias NixSwarmWeb.{ServiceIndexLive, ServiceShowLive, SnapshotFixture}

  setup do
    context = SnapshotFixture.broker_setup(__MODULE__)
    on_exit(fn -> SnapshotFixture.stop(context) end)
    context
  end

  test "lists service health, replicas, ownership, recovery contract, and metrics", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, ServiceIndexLive)

    assert html =~ "Services"
    assert html =~ "api"
    assert html =~ "worker"
    assert html =~ "2 desired replicas"
    assert html =~ "degraded"
    assert html =~ "awaiting_heal"
    assert html =~ "node-a@cluster"
    assert html =~ "auto_heal"
    assert html =~ "api@1.service"
    assert html =~ ~s(href="/services/YXBp")
  end

  test "shows service slots and an unknown service without creating atoms", %{conn: conn} do
    {:ok, _view, html} =
      live_isolated(conn, ServiceShowLive, session: %{"service" => "YXBp"})

    assert html =~ "Service api"
    assert html =~ "api@0.service"
    assert html =~ "Unplaced"
    assert html =~ "Awaiting heal"
    refute html =~ "worker@0.service"

    {:ok, _view, unknown_html} =
      live_isolated(conn, ServiceShowLive, session: %{"service" => "bm90LWluLXNuYXBzaG90"})

    assert unknown_html =~ "Unknown service"
    assert unknown_html =~ "current snapshot"
  end

  test "loads service logs through QueryBroker after an explicit refresh", %{
    conn: conn,
    broker: broker
  } do
    :sys.replace_state(broker, fn state ->
      %{state | query_fun: fn {:logs, "api", 200} -> {:ok, ["service api log"]} end}
    end)

    assert NixSwarmWeb.QueryBroker.snapshot(broker).services != []

    {:ok, view, html} =
      live_isolated(conn, ServiceShowLive, session: %{"service" => "YXBp"})

    refute html =~ "service api log"
    assert render_click(view, "load_logs", %{"lines" => "200"}) =~ "service api log"
    assert render(view) =~ "Fetched"
    assert render(view) =~ "api"
  end
end
