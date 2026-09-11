defmodule NixSwarmWeb.DashboardLiveTest do
  use NixSwarmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias NixSwarmWeb.QueryBroker

  defp snapshot(overrides \\ %{}) do
    base = %{
      captured_at: ~U[2026-09-05 12:00:00Z],
      queried_node: "node-a@cluster",
      stale?: false,
      nodes: [],
      services: [],
      summary: %{
        configured_nodes: 3,
        live_nodes: 2,
        placement_nodes: 2,
        services: 2,
        running_services: 2,
        degraded_services: 0,
        awaiting_heal_services: 0
      },
      drift: %{config_consistent?: true, digests: %{}, diagnostics: [], versions: []},
      graph: %{nodes: [], ownership_edges: []},
      metrics: %{cluster: %{}, nodes: %{}, services: %{}},
      errors: []
    }

    Map.merge(base, overrides)
  end

  setup do
    pubsub = Module.concat(__MODULE__, "PubSub")
    name = Module.concat(__MODULE__, "Broker")
    start_supervised!({Phoenix.PubSub, name: pubsub})
    start_supervised!({QueryBroker, name: name, pubsub_server: pubsub, start_immediately: false})
    Application.put_env(:nix_swarm_web, :query_broker_name, name)
    Application.put_env(:nix_swarm_web, :pubsub_server, pubsub)

    on_exit(fn ->
      Application.delete_env(:nix_swarm_web, :query_broker_name)
      Application.delete_env(:nix_swarm_web, :pubsub_server)
    end)

    :ok
  end

  test "renders loading state before the first snapshot", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Loading cluster status"
    assert html =~ "read-only"
    assert html =~ "Add New Machine"
    refute html =~ "Prepare the target machine"
  end

  test "renders healthy summary and the single cluster map", %{conn: conn} do
    QueryBroker.put_snapshot(QueryBroker.broker_name(), snapshot())
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Healthy"
    assert html =~ "Configured nodes"
    assert html =~ "3"
    assert html =~ "Live nodes"
    assert html =~ "Config consistent"
    assert html =~ ~s(id="cluster-map")
    refute html =~ ~s(class="app-nav")
  end

  test "renders degraded and stale metadata without replacing the last good summary", %{
    conn: conn
  } do
    current =
      snapshot(%{
        stale?: true,
        errors: [%{scope: "node", reason: "timeout"}],
        drift: %{config_consistent?: false, digests: %{}, diagnostics: [], versions: []}
      })

    QueryBroker.put_snapshot(QueryBroker.broker_name(), current)
    {:ok, view, html} = live(conn, "/")

    assert html =~ "Stale"
    assert html =~ "Degraded"
    assert html =~ "timeout"
    assert html =~ "3"
    refute html =~ "No cluster data"

    fresh = snapshot(%{summary: %{snapshot().summary | degraded_services: 1}})

    Phoenix.PubSub.broadcast(
      QueryBroker.pubsub_server(),
      "cluster:snapshot",
      {:cluster_snapshot, fresh}
    )

    assert render(view) =~ "Fresh · Degraded"
    assert render(view) =~ "Degraded services"
  end
end
