defmodule NixSwarm.ProxyAuthTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias NixSwarm.Proxy.Auth
  alias NixSwarm.Proxy.Config
  alias NixSwarm.Proxy.Oidc
  alias NixSwarm.Proxy.Session

  defmodule FakeOidcc do
    def create_redirect_url(_provider, _client_id, _secret, opts) do
      send(Process.get(:auth_test_pid), {:authorize, opts})
      {:ok, "https://pocket-id.example/authorize?state=#{opts.state}&code_challenge=challenge"}
    end

    def retrieve_token(code, _provider, _client_id, _secret, opts) do
      send(Process.get(:auth_test_pid), {:exchange, code, opts})

      {:ok,
       %{
         id_token: "id-token",
         refresh_token: "refresh-token",
         expires_at: 1_900_000_000,
         claims: %{"sub" => "user-1", "email" => "user@example.com"}
       }}
    end
  end

  setup do
    Process.put(:auth_test_pid, self())
    {:ok, session} = Session.new("0123456789abcdef0123456789abcdef")

    oidc_config = %Config.Oidc{
      issuer: "https://pocket-id.example",
      client_id: "client-123",
      scope: "openid email",
      redirect_base: "https://app.example"
    }

    {:ok, oidc} =
      Oidc.new(oidc_config,
        client_secret: "client-secret",
        provider: FakeOidcc,
        provider_ref: :provider
      )

    route = %Config.Route{
      name: "app",
      host: "app.example",
      path_prefix: "/app",
      upstreams: ["127.0.0.1:9999"],
      auth: :oidc,
      oidc: oidc_config
    }

    %{oidc: oidc, route: route, session: session}
  end

  test "public routes bypass authentication", %{route: route, session: session} do
    route = %{route | auth: :public}
    forwarder = fn conn, _route -> Plug.Conn.send_resp(conn, 200, "public") end
    conn = conn(:get, "http://app.example/app", "")

    conn = Auth.call(conn, route, session: session, forwarder: forwarder)

    assert conn.status == 200
    assert conn.resp_body == "public"
  end

  test "an unauthenticated OIDC request redirects with state and PKCE", %{
    oidc: oidc,
    route: route,
    session: session
  } do
    conn = conn(:get, "/app/dashboard", "")

    conn = Auth.call(conn, route, oidc: oidc, session: session, now: 1_800_000_000)

    assert conn.status == 302
    assert [location] = Plug.Conn.get_resp_header(conn, "location")
    assert location =~ "state="
    assert location =~ "code_challenge="
    assert [set_cookie] = Plug.Conn.get_resp_header(conn, "set-cookie")
    assert set_cookie =~ "nix_swarm_auth_state="
    assert_receive {:authorize, %{require_pkce: true}}
  end

  test "callback exchanges the code, sets the session, and returns to the original path", %{
    oidc: oidc,
    route: route,
    session: session
  } do
    {:ok, state_cookie} =
      Session.encode_state(
        session,
        %{
          state: "state-1",
          pkce_verifier: "verifier-1",
          return_path: "/app/dashboard",
          host: "app.example"
        },
        now: 1_800_000_000
      )

    conn =
      conn(:get, "http://app.example/__auth/callback?code=code-1&state=state-1", "")
      |> Plug.Conn.put_req_header("cookie", "nix_swarm_auth_state=#{state_cookie}")

    conn = Auth.call(conn, route, oidc: oidc, session: session, now: 1_800_000_000)

    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/app/dashboard"]

    assert Enum.any?(
             Plug.Conn.get_resp_header(conn, "set-cookie"),
             &String.starts_with?(&1, "nix_swarm_session=")
           )

    assert_receive {:exchange, "code-1", %{pkce_verifier: "verifier-1"}}
  end

  test "a valid session injects claim headers and forwards", %{
    oidc: oidc,
    route: route,
    session: session
  } do
    session_data = %{
      id_token: "id-token",
      refresh_token: "refresh-token",
      expires_at: 1_900_000_000,
      claims: %{"sub" => "user-1", "email" => "user@example.com"}
    }

    {:ok, cookie} = Session.encode(session, session_data, now: 1_800_000_000)

    forwarder = fn conn, _route ->
      assert Plug.Conn.get_req_header(conn, "x-auth-sub") == ["user-1"]
      assert Plug.Conn.get_req_header(conn, "x-auth-email") == ["user@example.com"]
      Plug.Conn.send_resp(conn, 200, "authorized")
    end

    conn =
      conn(:get, "http://app.example/app", "")
      |> Plug.Conn.put_req_header("cookie", "nix_swarm_session=#{cookie}")

    conn =
      Auth.call(conn, route,
        oidc: oidc,
        session: session,
        forwarder: forwarder,
        now: 1_800_000_000
      )

    assert conn.status == 200
    assert conn.resp_body == "authorized"
  end

  test "an expired session starts authentication again", %{
    oidc: oidc,
    route: route,
    session: session
  } do
    session_data = %{
      id_token: "id-token",
      refresh_token: "refresh-token",
      expires_at: 1_700_000_000,
      claims: %{"sub" => "user-1"}
    }

    {:ok, cookie} = Session.encode(session, session_data, now: 1_600_000_000)

    conn =
      conn(:get, "http://app.example/app", "")
      |> Plug.Conn.put_req_header("cookie", "nix_swarm_session=#{cookie}")

    conn = Auth.call(conn, route, oidc: oidc, session: session, now: 1_800_000_000)

    assert conn.status == 302
    assert_receive {:authorize, _}
  end

  test "callback rejects a return host that is not the configured route host", %{
    oidc: oidc,
    route: route,
    session: session
  } do
    {:ok, state_cookie} =
      Session.encode_state(
        session,
        %{
          state: "state-1",
          pkce_verifier: "verifier-1",
          return_path: "https://evil.example/",
          host: "evil.example"
        },
        now: 1_800_000_000
      )

    conn =
      conn(:get, "http://app.example/__auth/callback?code=code-1&state=state-1", "")
      |> Plug.Conn.put_req_header("cookie", "nix_swarm_auth_state=#{state_cookie}")

    conn = Auth.call(conn, route, oidc: oidc, session: session, now: 1_800_000_000)

    assert conn.status == 400
    refute_receive {:exchange, _, _}
  end
end
