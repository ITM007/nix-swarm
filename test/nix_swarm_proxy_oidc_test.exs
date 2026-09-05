defmodule NixSwarm.ProxyOidcTest do
  use ExUnit.Case, async: false

  alias NixSwarm.Proxy.Config
  alias NixSwarm.Proxy.Oidc

  defmodule FakeOidcc do
    def create_redirect_url(provider, client_id, client_secret, opts) do
      send(Process.get(:oidc_test_pid), {:redirect, provider, client_id, client_secret, opts})
      {:ok, "http://issuer.example/authorize?state=#{opts.state}&code_challenge=challenge"}
    end

    def retrieve_token(code, provider, client_id, client_secret, opts) do
      send(
        Process.get(:oidc_test_pid),
        {:exchange, code, provider, client_id, client_secret, opts}
      )

      {:ok,
       %{
         id_token: "id-token",
         refresh_token: "refresh-token",
         expires_at: 1_900_000_000,
         claims: %{"sub" => "user-1", "email" => "user@example.com"}
       }}
    end

    def refresh_token(refresh_token, provider, client_id, client_secret, opts) do
      send(
        Process.get(:oidc_test_pid),
        {:refresh, refresh_token, provider, client_id, client_secret, opts}
      )

      {:ok,
       %{
         id_token: "new-id-token",
         refresh_token: "new-refresh-token",
         expires_at: 1_900_000_100,
         claims: %{"sub" => "user-1"}
       }}
    end
  end

  defmodule RealShapeOidcc do
    def retrieve_token(_code, _provider, _client_id, _client_secret, _opts) do
      {:ok,
       %Oidcc.Token{
         id: %Oidcc.Token.Id{token: "id-token", claims: %{"sub" => "user-1"}},
         access: %Oidcc.Token.Access{token: "access-token", expires: 3600, type: "Bearer"},
         refresh: %Oidcc.Token.Refresh{token: "refresh-token"},
         scope: []
       }}
    end
  end

  setup do
    Process.put(:oidc_test_pid, self())

    config = %Config.Oidc{
      issuer: "https://issuer.example",
      client_id: "client-123",
      scope: "openid email"
    }

    {:ok, oidc} =
      Oidc.new(config,
        client_secret: "client-secret",
        provider: FakeOidcc,
        provider_ref: :provider
      )

    %{oidc: oidc}
  end

  test "authorization uses discovery-backed oidcc with state and PKCE", %{oidc: oidc} do
    assert {:ok, result} = Oidc.authorize(oidc, "https://app.example/__auth/callback")
    assert result.state != ""
    assert result.pkce_verifier != ""
    assert result.nonce != ""
    assert result.authorization_url =~ "state="
    assert result.authorization_url =~ "code_challenge="

    assert_receive {:redirect, :provider, "client-123", "client-secret", opts}
    assert opts.redirect_uri == "https://app.example/__auth/callback"
    assert opts.state == result.state
    assert opts.pkce_verifier == result.pkce_verifier
    assert opts.nonce == result.nonce
    assert opts.require_pkce
    assert opts.scopes == ["openid", "email"]
  end

  test "converts the Oidcc access-token lifetime to an absolute expiry", %{oidc: oidc} do
    oidc = %{oidc | provider: RealShapeOidcc}
    before = System.system_time(:second)

    assert {:ok, token} =
             Oidc.exchange(
               oidc,
               "authorization-code",
               "https://app.example/__auth/callback",
               "verifier"
             )

    assert token.expires_at in (before + 1)..(before + 3600)
  end

  test "exchange maps the validated oidcc token to the session shape", %{oidc: oidc} do
    assert {:ok, token} =
             Oidc.exchange(
               oidc,
               "authorization-code",
               "https://app.example/__auth/callback",
               "verifier"
             )

    assert token == %{
             id_token: "id-token",
             refresh_token: "refresh-token",
             expires_at: 1_900_000_000,
             claims: %{"sub" => "user-1", "email" => "user@example.com"}
           }

    assert_receive {:exchange, "authorization-code", :provider, "client-123", "client-secret",
                    opts}

    assert opts.redirect_uri == "https://app.example/__auth/callback"
    assert opts.pkce_verifier == "verifier"
    assert opts.require_pkce
  end

  test "refresh delegates the refresh grant", %{oidc: oidc} do
    session = %{refresh_token: "refresh-token", claims: %{"sub" => "user-1"}}
    assert {:ok, refreshed} = Oidc.refresh(oidc, session)
    assert refreshed.refresh_token == "new-refresh-token"
    assert refreshed.expires_at == 1_900_000_100
    assert_receive {:refresh, "refresh-token", :provider, "client-123", "client-secret", _opts}
  end

  test "rejects non-http issuer URLs" do
    assert {:error, {:invalid_issuer, _reason}} =
             Oidc.new(%Config.Oidc{issuer: "ftp://issuer.example", client_id: "client"},
               client_secret: "secret",
               provider: FakeOidcc,
               provider_ref: :provider
             )
  end

  test "reads the client secret from the credentials directory" do
    path =
      Path.join(System.tmp_dir!(), "nix-swarm-oidc-secret-#{System.unique_integer([:positive])}")

    File.write!(path, "from-file\n")

    on_exit(fn -> File.rm(path) end)

    assert {:ok, oidc} =
             Oidc.new(
               %Config.Oidc{issuer: "https://issuer.example", client_id: "client"},
               client_secret_file: path,
               provider: FakeOidcc,
               provider_ref: :provider
             )

    assert oidc.client_secret == "from-file"
  end

  test "surfaces provider failures as structured errors", %{oidc: oidc} do
    defmodule FailingOidcc do
      def create_redirect_url(_provider, _client_id, _secret, _opts),
        do: {:error, {:http_status, 503}}
    end

    oidc = %{oidc | provider: FailingOidcc}

    assert {:error, {:oidc_error, {:http_status, 503}}} =
             Oidc.authorize(oidc, "https://app.example/callback")
  end
end
