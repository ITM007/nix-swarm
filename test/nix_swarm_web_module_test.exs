defmodule NixSwarmWebModuleTest do
  use ExUnit.Case, async: false

  @module_path "nix/nix-swarm-web/module.nix"

  test "web module is inert when disabled" do
    result =
      eval_module!("""
      {
        has_user = node.config.users.users ? "nix-swarm-web";
        has_group = node.config.users.groups ? "nix-swarm-web";
        has_service = node.config.systemd.services ? "nix-swarm-web";
        has_registration = node.config.services.nix-swarm.services ? "nix-swarm-web";
        firewall = node.config.networking.firewall.allowedTCPPorts;
      }
      """)

    refute result["has_user"]
    refute result["has_group"]
    refute result["has_service"]
    refute result["has_registration"]
    assert result["firewall"] == []
  end

  test "enabled web module is loopback-only, read-only, and cluster-managed" do
    result =
      eval_module!(
        """
        let
          service = node.config.systemd.services."nix-swarm-web";
          serviceConfig = service.serviceConfig;
          registration = node.config.services.nix-swarm.services."nix-swarm-web";
        in {
          user = node.config.users.users."nix-swarm-web";
          serviceConfig = serviceConfig;
          wantedBy = service.wantedBy;
          registration = registration;
          firewall = node.config.networking.firewall.allowedTCPPorts;
          exec_start = builtins.readFile serviceConfig.ExecStart;
        }
        """,
        """
          services.nix-swarm-web = {
            enable = true;
            package = pkgs.runCommand "nix-swarm-web-test-package" {} ''
              mkdir -p "$out/bin"
              touch "$out/bin/nix-swarm-web"
              chmod 0755 "$out/bin/nix-swarm-web"
            '';
            port = 4317;
            querySocket = "/run/test/query.sock";
            pollIntervalMs = 700;
            configSource = "/etc/nix-swarm/source";
            allowedNodes = [ "nix-swarm@node-a.test" ];
          };
        """
      )

    assert result["user"]["isSystemUser"]
    assert result["user"]["group"] == "nix-swarm-web"
    assert result["user"]["extraGroups"] == ["nix-swarm-operators"]

    service_config = result["serviceConfig"]
    assert service_config["User"] == "nix-swarm-web"
    assert service_config["Group"] == "nix-swarm-web"
    assert service_config["SupplementaryGroups"] == ["nix-swarm-operators"]
    assert service_config["RuntimeDirectory"] == "nix-swarm-web"
    assert service_config["RuntimeDirectoryMode"] == "0700"
    assert service_config["UMask"] == "0077"
    assert service_config["NoNewPrivileges"]
    assert service_config["PrivateTmp"]
    assert service_config["ProtectSystem"] == "strict"
    assert service_config["ProtectHome"]
    assert service_config["RestrictAddressFamilies"] == ["AF_UNIX", "AF_INET"]
    assert service_config["CapabilityBoundingSet"] == ""
    assert service_config["LoadCredential"] == []
    assert service_config["MemoryMax"] == "512M"
    assert service_config["TasksMax"] == 256
    assert service_config["LimitNOFILE"] == 4096
    refute service_config["ReadWritePaths"]

    assert result["wantedBy"] == []
    assert result["firewall"] == []

    assert Enum.sort(service_config["Environment"]) ==
             Enum.sort([
               "NIX_SWARM_POLL_INTERVAL_MS=700",
               "NIX_SWARM_CONFIG_SOURCE=/etc/nix-swarm/source",
               "NIX_SWARM_QUERY_SOCKET=/run/test/query.sock",
               "PHX_HOST=127.0.0.1",
               "PHX_SERVER=true",
               "PORT=4317"
             ])

    assert result["registration"]["replicas"] == 1
    assert result["registration"]["unitTemplate"] == "nix-swarm-web.service"
    assert result["registration"]["allowedNodes"] == ["nix-swarm@node-a.test"]
    assert result["registration"]["autoscaling"]["enable"] == false
    assert result["registration"]["autoscaling"]["maxReplicas"] == 1
    assert result["registration"]["state"] == nil

    assert result["exec_start"] =~ "SECRET_KEY_BASE_FILE"
    refute result["exec_start"] =~ "NIX_SWARM_COOKIE"
    assert result["exec_start"] =~ "RELEASE_DISTRIBUTION=none"
    refute result["exec_start"] =~ "SSH"
    refute result["exec_start"] =~ "GIT"
    refute result["exec_start"] =~ "NIX_SWARM_SOURCE"
  end

  test "the flake exports the real web VM smoke check" do
    {output, status} =
      System.cmd("nix", ["eval", "--raw", ".#checks.x86_64-linux.web-vm.name"],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert "vm-test-run-nix-swarm-web" in String.split(output, "\n")
  end

  defp eval_module!(body, web_config \\ "") do
    root =
      File.cwd!()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    module_path = Path.join(root, @module_path)

    expression =
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
              };
              #{web_config}
            })
          ];
        };
      in #{body}
      """
      |> String.trim()

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
end
