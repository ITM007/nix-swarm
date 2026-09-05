defmodule NixSwarmWeb.DriftLiveTest do
  use NixSwarmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias NixSwarmWeb.{DriftLive, SnapshotFixture}

  setup do
    context = SnapshotFixture.broker_setup(__MODULE__)
    on_exit(fn -> SnapshotFixture.stop(context) end)
    context
  end

  test "groups digest, version, desired-observed, placement, and node findings by severity", %{
    conn: conn
  } do
    {:ok, _view, html} = live_isolated(conn, DriftLive)

    assert html =~ "Configuration drift"
    assert html =~ "config digest mismatch"
    assert html =~ "Mixed release versions"
    assert html =~ "release_version"
    assert html =~ "unplaced_slot"
    assert html =~ "node_unreachable"
    assert html =~ "error"
    assert html =~ "warning"
  end

  test "does not infer healthy consistency when digests are missing", %{conn: conn} do
    snapshot = %{
      SnapshotFixture.snapshot()
      | drift: %{config_consistent?: nil, digests: %{}, diagnostics: [], versions: %{}},
        nodes: []
    }

    NixSwarmWeb.QueryBroker.put_snapshot(NixSwarmWeb.QueryBroker.broker_name(), snapshot)

    {:ok, _view, html} = live_isolated(conn, DriftLive)

    assert html =~ "Unknown"
    assert html =~ "not enough data"
    refute html =~ "In sync"
  end
end
