defmodule NixSwarmWeb.HealthControllerTest do
  use NixSwarmWeb.ConnCase, async: true

  test "GET /healthz returns a small JSON health response", %{conn: conn} do
    conn = get(conn, "/healthz")

    assert response(conn, 200) == ~s({"status":"ok"})
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
  end

  test "rejects an unrecognized HTTP authority before serving data", %{conn: conn} do
    conn = %{conn | host: "attacker.example"}

    conn = get(conn, "/healthz")

    assert conn.status == 400
    assert response(conn, 400) == "invalid host\n"
  end

  test "accepts the development browser authority", %{conn: conn} do
    conn = %{conn | host: "nix-swarm-dev.localhost"}

    conn = get(conn, "/healthz")

    assert response(conn, 200) == ~s({"status":"ok"})
  end

  test "unknown routes return a rendered 404 response", %{conn: conn} do
    conn = get(conn, "/missing")

    assert response(conn, 404) =~ "404"
  end

  test "the web project has no database or account surface" do
    mix_source = File.read!(Path.expand("../../mix.exs", __DIR__))
    router_source = File.read!(Path.expand("../../lib/nix_swarm_web/router.ex", __DIR__))

    refute mix_source =~ ~r/ecto|oauth|account|role/i
    refute router_source =~ ~r/(login|oauth|account|role|session_identity)/i
  end

  test "production runtime configuration hard-binds IPv4 loopback" do
    runtime_source = File.read!(Path.expand("../../config/runtime.exs", __DIR__))

    assert runtime_source =~ "ip: {127, 0, 0, 1}"
    refute runtime_source =~ "NIX_SWARM_WEB_BIND"
  end
end
