defmodule NixSwarmWeb.LogsLiveTest do
  use NixSwarmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias NixSwarmWeb.{LogsLive, SnapshotFixture}

  setup do
    context = SnapshotFixture.broker_setup(__MODULE__)
    on_exit(fn -> SnapshotFixture.stop(context) end)
    context
  end

  test "starts with the bounded default and refreshes cluster logs through the broker", %{
    conn: conn,
    broker: broker
  } do
    :sys.replace_state(broker, fn state ->
      %{
        state
        | query_fun: fn {:cluster_logs, "node-a@cluster", 200} ->
            {:ok, ["INFO ready", "ERROR needle"]}
          end
      }
    end)

    {:ok, view, html} = live_isolated(conn, LogsLive)
    assert html =~ "200 lines"
    refute html =~ "ERROR needle"

    html =
      render_click(view, "refresh", %{
        "scope" => "cluster",
        "target" => "node-a@cluster",
        "lines" => "200"
      })

    assert html =~ "ERROR needle"
    assert html =~ "Source node-a@cluster"
    assert html =~ "Fetched"

    assert render_click(view, "filter", %{"filter" => "errors"}) =~ "ERROR needle"
    refute render(view) =~ "INFO ready"
    assert render_click(view, "search", %{"query" => "needle"}) =~ "1 match"
    assert render_click(view, "next_match", %{}) =~ "Match 1 of 1"
  end

  test "supports service and node scopes and displays partial errors", %{
    conn: conn,
    broker: broker
  } do
    :sys.replace_state(broker, fn state ->
      %{
        state
        | query_fun: fn
            {:logs, "api", 1_000} -> {:ok, %{"lines" => ["service api"]}}
            {:node_service_logs, "node-c@cluster", 200} -> {:error, :node_unreachable}
          end
      }
    end)

    {:ok, view, _html} = live_isolated(conn, LogsLive)

    assert render_click(view, "refresh", %{
             "scope" => "service",
             "target" => "api",
             "lines" => "1000"
           }) =~ "service api"

    assert render_click(view, "refresh", %{
             "scope" => "node",
             "target" => "node-c@cluster",
             "lines" => "200"
           }) =~ "Partial log result"

    assert render(view) =~ "node_unreachable"
  end
end
