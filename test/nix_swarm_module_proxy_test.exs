defmodule NixSwarmModuleProxyTest do
  use ExUnit.Case, async: false

  @module_path "nix/nix-swarm/module.nix"

  test "proxy is disabled by default and renders no proxy artifacts" do
    result =
      eval_module!("""
      {
        has_proxy_service = node.config.systemd.services ? "nix-swarm-proxy";
        has_proxy_firewall = node.config.networking.firewall.interfaces ? netbird0;
      }
      """)

    refute result["has_proxy_service"]
    refute result["has_proxy_firewall"]
  end

  test "enabled proxy renders config, service, credentials, and scoped firewall" do
    result =
      eval_module!(
        """
        let
          service = node.config.systemd.services."nix-swarm-proxy";
          environment = service.serviceConfig.Environment;
          config_path = builtins.replaceStrings
            ["NIX_SWARM_PROXY_CONFIG_PATH="]
            [""]
            (builtins.elemAt (builtins.filter (value: builtins.match "NIX_SWARM_PROXY_CONFIG_PATH=.*" value != null) environment) 0);
        in {
          has_proxy_service = node.config.systemd.services ? "nix-swarm-proxy";
          type = service.serviceConfig.Type;
          restart = service.serviceConfig.Restart;
          exec_start = builtins.readFile service.serviceConfig.ExecStart;
          load_credential = service.serviceConfig.LoadCredential;
          environment = environment;
          config = builtins.readFile config_path;
          firewall = node.config.networking.firewall.interfaces.netbird0.allowedTCPPorts;
          other_firewall = node.config.networking.firewall.interfaces ? eth0;
        }
        """,
        """
          proxy = {
            enable = true;
            listen.port = 9090;
            openFirewall = true;
            firewallInterfaces = [ "netbird0" ];
            clientSecretFile = "/etc/nix-swarm/proxy-client-secret";
            sessionSecretFile = "/etc/nix-swarm/proxy-session-secret";
            oidc = {
              issuer = "https://pocket-id.example";
              clientId = "nix-swarm";
            };
            routes = {
              public = {
                host = "public.example";
                pathPrefix = "/";
                upstreams = [ "127.0.0.1:8080" ];
                auth = "public";
              };
              private = {
                host = "private.example";
                pathPrefix = "/app";
                upstreams = [ "127.0.0.1:8081" ];
                auth = "oidc";
                oidc.redirectBase = "https://private.example";
              };
            };
          };
        """
      )

    assert result["has_proxy_service"]
    assert result["type"] == "simple"
    assert result["restart"] == "on-failure"
    assert result["exec_start"] =~ "nix-swarmd proxy"

    assert result["load_credential"] == [
             "proxy-client-secret:/etc/nix-swarm/proxy-client-secret",
             "proxy-session-secret:/etc/nix-swarm/proxy-session-secret"
           ]

    assert result["firewall"] == [9090]
    refute result["other_firewall"]
    assert Enum.any?(result["environment"], &(&1 == "NIX_SWARM_ROLE=proxy"))
    refute result["config"] =~ "proxy-client-secret"
    refute result["config"] =~ "proxy-session-secret"
    assert result["config"] =~ "listen_port"
    assert result["config"] =~ "public.example"
    assert result["config"] =~ "private.example"
    assert result["config"] =~ "pocket-id.example"
  end

  test "proxy rejects invalid route hosts and upstreams" do
    assert_eval_fails!(
      """
      proxy = {
        enable = true;
        routes.bad = {
          host = "";
          upstreams = [ "https://evil.example:443/path" ];
        };
      };
      """,
      "route host must be non-empty"
    )

    assert_eval_fails!(
      """
      proxy = {
        enable = true;
        routes.empty = {
          host = "empty.example";
        };
      };
      """,
      "route upstreams must not be empty"
    )

    assert_eval_fails!(
      """
      proxy = {
        enable = true;
        routes.bad = {
          host = "bad.example";
          upstreams = [ "https://evil.example:443/path" ];
        };
      };
      """,
      "proxy upstreams must match host:port"
    )

    assert_eval_fails!(
      """
      proxy = {
        enable = true;
        routes."bad/name" = {
          host = "bad.example";
          upstreams = [ "127.0.0.1:8080" ];
        };
      };
      """,
      "route names must contain only safe characters"
    )

    assert_eval_fails!(
      """
      proxy = {
        enable = true;
        routes.bad = {
          host = "bad.example";
          upstreams = [ "127.0.0.1:65536" ];
        };
      };
      """,
      "proxy upstreams must match host:port"
    )

    assert_eval_fails!(
      """
      proxy = {
        enable = true;
        routes.bad = {
          host = "bad.example";
          pathPrefix = "bad";
          upstreams = [ "127.0.0.1:8080" ];
        };
      };
      """,
      "proxy pathPrefix must be an absolute path"
    )
  end

  test "proxy rejects unscoped firewall and store secret paths" do
    assert_eval_fails!(
      """
      proxy = {
        enable = true;
        openFirewall = true;
        oidc.clientId = "client";
      };
      """,
      "proxy.openFirewall requires firewallInterfaces"
    )

    assert_eval_fails!(
      """
      proxy = {
        enable = true;
        clientSecretFile = "/nix/store/secret";
        sessionSecretFile = "/run/secrets/session";
      };
      """,
      "proxy.clientSecretFile must be an absolute, out-of-store secret path"
    )

    assert_eval_fails!(
      """
      proxy = {
        enable = true;
        sessionSecretFile = "/nix/store/session";
      };
      """,
      "proxy.sessionSecretFile must be an absolute, out-of-store secret path"
    )

    assert_eval_fails!(
      """
      proxy = {
        enable = true;
        routes.private = {
          host = "private.example";
          upstreams = [ "127.0.0.1:8080" ];
          auth = "oidc";
        };
      };
      """,
      "proxy.oidc.clientId must not be empty"
    )

    assert_eval_fails!(
      """
      proxy = {
        enable = true;
        clientSecretFile = "/run/secrets/client";
        sessionSecretFile = "/run/secrets/session";
        oidc.clientId = "client";
        routes.private = {
          host = "private.example";
          upstreams = [ "127.0.0.1:8080" ];
          auth = "oidc";
          oidc.redirectBase = "https://private.example";
        };
      };
      """,
      "proxy.oidc.issuer must be an absolute http(s) URL"
    )
  end

  defp eval_module!(body, proxy_config \\ "", extra \\ "") do
    expression = module_expression(body, proxy_config, extra)

    case System.cmd("nix", ["eval", "--impure", "--json", "--expr", expression],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        json = Enum.find(String.split(output, "\n"), &String.starts_with?(&1, "{"))

        case JSON.decode(json || "") do
          {:ok, value} -> value
          {:error, _reason} -> flunk("nix eval returned non-JSON output:\n#{output}")
        end

      {output, status} ->
        flunk("nix eval failed with status #{status}:\n#{output}")
    end
  end

  defp assert_eval_fails!(proxy_config, message) do
    expression =
      module_expression("builtins.seq node.config.system.build.toplevel {}", proxy_config)

    {output, status} =
      System.cmd("nix", ["eval", "--impure", "--json", "--expr", expression],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ message
  end

  defp module_expression(body, proxy_config, extra \\ "") do
    root = File.cwd!() |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    module_path = Path.join(root, @module_path)

    """
    let
      flake = builtins.getFlake "#{root}";
      pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
      node = flake.inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          (import "#{module_path}")
          ({ ... }: {
            boot.loader.grub.devices = [ "nodev" ];
            fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
            system.stateVersion = "25.11";
            services.nix-swarm = {
              enable = true;
              package = pkgs.runCommand "nix-swarm-test-package" {} "mkdir -p $out/bin";
              nodeName = "nix-swarm@node-a.test";
              cookieFile = "/run/keys/nix-swarm.cookie";
              peers = [ "nix-swarm@node-a.test" ];
              nodes."nix-swarm@node-a.test".deployHost = "root@node-a.test";
              #{proxy_config}
            };
            #{extra}
          })
        ];
      };
    in #{body}
    """
    |> String.trim()
  end
end
