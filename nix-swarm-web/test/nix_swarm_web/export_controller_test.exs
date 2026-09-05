defmodule NixSwarmWeb.ExportControllerTest do
  use NixSwarmWeb.ConnCase, async: true

  alias NixSwarmWeb.ExportController

  @snapshot %{
    captured_at: ~U[2026-09-05 12:34:56Z],
    captured_at_ms: 1_788_604_496_000,
    queried_node: "node-é",
    stale?: true,
    nodes: [%{name: "node-é", host: "host", status: "unknown", services: [], error: nil}],
    services: [],
    drift: %{config_consistent?: nil},
    graph: %{},
    metrics: %{},
    errors: [%{scope: "node", node: "node-é", reason: "timeout"}]
  }

  test "snapshot response is an in-memory UTF-8 download with a safe filename", %{conn: conn} do
    conn = ExportController.snapshot_response(conn, @snapshot)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="snapshot.json")
           ]

    assert response(conn, 200) =~ "node-é"
  end

  test "CSV and text response helpers set content disposition without writing files", %{
    conn: conn
  } do
    conn = ExportController.nodes_response(conn, @snapshot)
    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="nodes.csv")]
    assert response(conn, 200) =~ "node-é"

    conn = build_conn()
    conn = ExportController.services_response(conn, @snapshot)

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="services.csv")
           ]

    conn = build_conn()
    conn = ExportController.logs_response(conn, %{"logs" => ["warning: café"]})
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="logs.txt")]
    assert response(conn, 200) == "warning: café"
  end

  test "log request validation whitelists scope, target, and bounded lines" do
    assert ExportController.log_request(%{
             "scope" => "service",
             "target" => "api",
             "lines" => "20",
             "ignored" => "drop"
           }) ==
             {:ok, {:service, "api", 20}}

    assert ExportController.log_request(%{"scope" => "node", "node" => "node@host"}) ==
             {:ok, {:node, "node@host", 200}}

    assert ExportController.log_request(%{
             "scope" => "cluster",
             "target" => "node@host",
             "lines" => "1001"
           }) ==
             {:error, :invalid_lines}

    assert ExportController.log_request(%{"scope" => "shell", "target" => "bad"}) ==
             {:error, :invalid_log_scope}
  end
end
