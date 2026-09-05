defmodule NixSwarm.Proxy.ConfigTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Proxy.Config

  defp valid_raw do
    %{
      listen_port: 8080,
      session_ttl_sec: 3600,
      oidc: %{issuer: "http://pocket-id.internal", client_id: "nix-swarm-edge"},
      routes: [
        %{
          name: "web",
          host: "app.internal",
          path_prefix: "/",
          upstreams: ["127.0.0.1:8081", "10.0.0.2:8081"],
          auth: "oidc",
          oidc: %{redirect_base: "http://app.internal", scope: "openid email profile"}
        },
        %{name: "health", host: "status.internal", upstreams: ["127.0.0.1:8082"], auth: "public"}
      ]
    }
  end

  defp valid_route do
    %{
      name: "web",
      host: "app.internal",
      path_prefix: "/",
      upstreams: ["127.0.0.1:8081"],
      auth: "public"
    }
  end

  describe "normalize/1" do
    test "parses a map config with snake_case atom keys" do
      config = Config.normalize(valid_raw())

      assert config.listen_port == 8080
      assert config.session_ttl_sec == 3600
      assert config.oidc.issuer == "http://pocket-id.internal"
      assert config.oidc.client_id == "nix-swarm-edge"
      assert config.oidc.scope == "openid email profile"

      assert [web, health] = config.routes
      assert web.name == "web"
      assert web.host == "app.internal"
      assert web.path_prefix == "/"
      assert web.upstreams == ["127.0.0.1:8081", "10.0.0.2:8081"]
      assert web.auth == :oidc
      assert web.oidc.redirect_base == "http://app.internal"
      assert health.auth == :public
      assert health.oidc == nil
    end

    test "parses a serializer-shaped term file body (single proplist, binary values)" do
      raw = [
        listen_port: 8080,
        routes: [
          [name: "web", host: "app.internal", upstreams: ["127.0.0.1:8081"], auth: "public"]
        ]
      ]

      config = Config.normalize(raw)

      assert config.listen_port == 8080
      assert [%{name: "web", auth: :public}] = config.routes
    end

    test "accepts atom auth tags and :undefined oidc blocks" do
      raw =
        valid_raw()
        |> Map.put(:routes, [
          Map.put(valid_route(), :auth, :oidc)
          |> Map.put(:oidc, :undefined)
        ])
        |> Map.put(:oidc, %{issuer: "http://pocket-id.internal", client_id: "c1"})

      config = Config.normalize(raw)

      assert [route] = config.routes
      assert route.auth == :oidc
      assert route.oidc == nil
    end

    test "defaults session_ttl_sec, scope, and path_prefix when absent" do
      raw = %{
        listen_port: 8080,
        oidc: %{issuer: "http://pocket-id.internal", client_id: "c1"},
        routes: [
          %{name: "web", host: "app.internal", upstreams: ["127.0.0.1:8081"], auth: "public"}
        ]
      }

      config = Config.normalize(raw)

      assert config.session_ttl_sec == 3600
      assert config.oidc.scope == "openid email profile"
      assert [route] = config.routes
      assert route.path_prefix == "/"
    end
  end

  describe "validate/1" do
    test "accepts a valid public+oidc config" do
      assert Config.validate(Config.normalize(valid_raw())) == :ok
    end

    test "rejects a missing listen_port" do
      config = valid_raw() |> Map.delete(:listen_port) |> Config.normalize()

      assert {:error, message} = Config.validate(config)
      assert message =~ "listen_port"
    end

    test "rejects an oidc route without a top-level issuer" do
      raw =
        valid_raw()
        |> Map.delete(:oidc)
        |> Map.put(:routes, [Map.put(valid_route(), :auth, "oidc")])

      config = Config.normalize(raw)

      assert {:error, message} = Config.validate(config)
      assert message =~ "issuer"
    end

    test "rejects an oidc route without a route redirect_base" do
      raw =
        valid_raw()
        |> Map.put(:routes, [
          valid_route()
          |> Map.put(:auth, "oidc")
          |> Map.put(:oidc, %{})
        ])

      config = Config.normalize(raw)

      assert {:error, message} = Config.validate(config)
      assert message =~ "redirect_base"
    end

    test "rejects a non-absolute redirect_base" do
      raw =
        valid_raw()
        |> Map.put(:routes, [
          valid_route()
          |> Map.put(:auth, "oidc")
          |> Map.put(:oidc, %{redirect_base: "app.internal"})
        ])

      config = Config.normalize(raw)

      assert {:error, message} = Config.validate(config)
      assert message =~ "redirect_base"
    end

    test "rejects unsafe upstream strings" do
      for upstream <- ["http://10.0.0.2:8081", "user@10.0.0.2:8081", "10.0.0.2:8081/path", ""] do
        raw = %{
          listen_port: 8080,
          routes: [Map.put(valid_route(), :upstreams, [upstream])]
        }

        config = Config.normalize(raw)

        assert {:error, message} = Config.validate(config)
        assert message =~ "upstream"
      end
    end

    test "rejects an unknown auth tag" do
      raw = %{
        listen_port: 8080,
        routes: [Map.put(valid_route(), :auth, "saml")]
      }

      config = Config.normalize(raw)

      assert {:error, message} = Config.validate(config)
      assert message =~ "auth"
    end

    test "rejects empty upstream lists and empty hosts" do
      for mutate <- [
            &Map.put(&1, :upstreams, []),
            &Map.put(&1, :host, "")
          ] do
        raw = %{listen_port: 8080, routes: [mutate.(valid_route())]}

        config = Config.normalize(raw)

        assert {:error, message} = Config.validate(config)
        assert message =~ "route"
      end
    end

    test "rejects unsafe route names" do
      raw = %{
        listen_port: 8080,
        routes: [Map.put(valid_route(), :name, "../escape")]
      }

      config = Config.normalize(raw)

      assert {:error, message} = Config.validate(config)
      assert message =~ "route name"
    end

    test "accepts a public-only config with no oidc block" do
      raw = %{listen_port: 8080, routes: [valid_route()]}

      config = Config.normalize(raw)

      assert Config.validate(config) == :ok
    end
  end
end
