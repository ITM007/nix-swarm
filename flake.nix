{
  description = "Nix-Swarm leaderless NixOS cluster runtime";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f system (import nixpkgs { inherit system; })
        );
    in
    {
      lib.mkDeploymentManifest = configurations:
        let
          inherit (nixpkgs.lib) attrValues filter foldl' recursiveUpdate;
          enabled = filter (configuration: configuration.config.services.nix-swarm.enable) (attrValues configurations);
          mergedNodes = foldl' recursiveUpdate { } (map (configuration: configuration.config.services.nix-swarm.nodes) enabled);

        in
        {
          schemaVersion = 1;
          nodes = mergedNodes;
        };

      lib.nixSwarm.deploymentManifest = {
        schemaVersion = 1;
        nodes = {
          "nix-swarm@example-node-a.local" = {
            availability = "active";
            deployHost = "root@example-node-a.local";
            nixosConfiguration = "example-node-a";
          };
          "nix-swarm@example-node-b.local" = {
            availability = "active";
            deployHost = "root@example-node-b.local";
            nixosConfiguration = "example-node-b";
          };
        };

      };

      packages = forAllSystems (_system: pkgs:
        let
          nixSwarm = import ./nix/nix-swarm/packages.nix { inherit pkgs; };
          nixSwarmWeb = import ./nix/nix-swarm-web/packages.nix { inherit pkgs; };
        in
        {
          default = nixSwarm.combined;
          nix-swarm = nixSwarm.combined;
          operator = nixSwarm.operator;
          cluster = nixSwarm.cluster;
          nix-swarm-web = nixSwarmWeb.nix-swarm-web;
          nix-swarm-operator = nixSwarm.operator;
          nix-swarm-cluster = nixSwarm.cluster;
        });

      apps = forAllSystems (_system: pkgs:
        let
          nixSwarm = import ./nix/nix-swarm/packages.nix { inherit pkgs; };
        in
        {
          default = {
            type = "app";
            program = "${nixSwarm.operator}/bin/nix-swarm";
            meta.description = "Nix-Swarm read-only operator and code-first deployment CLI";
          };
          operator = {
            type = "app";
            program = "${nixSwarm.operator}/bin/nix-swarm";
            meta.description = "Nix-Swarm read-only operator and code-first deployment CLI";
          };
        });

      devShells = forAllSystems (_system: pkgs: {
        default =
          let
            beamPackages = pkgs.beamPackages;
          in
          pkgs.mkShell {
            packages = [
              beamPackages.elixir_1_20
              beamPackages.erlang
              beamPackages.rebar3
              pkgs.git
              pkgs.nixpkgs-fmt
            ];
          };
      });

      formatter = forAllSystems (_system: pkgs: pkgs.nixpkgs-fmt);

      checks = forAllSystems (system: pkgs:
        let
          nixSwarm = import ./nix/nix-swarm/packages.nix { inherit pkgs; };
          nixSwarmWeb = import ./nix/nix-swarm-web/packages.nix { inherit pkgs; };

          minimalNode = module:
            nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                module
                ({ ... }: {
                  boot.loader.grub.devices = [ "nodev" ];
                  fileSystems."/" = {
                    device = "none";
                    fsType = "tmpfs";
                  };
                  system.stateVersion = "25.11";
                })
              ];
            };

          webBaselineNode = minimalNode self.nixosModules.nix-swarm;
          webDisabledNode = minimalNode self.nixosModules.nix-swarm-web;

          webTestPackage = pkgs.runCommand "nix-swarm-web-test-package" { } ''
            mkdir -p "$out/bin"
            touch "$out/bin/nix-swarm-web"
            chmod 0755 "$out/bin/nix-swarm-web"
          '';

          webEnabledNode = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.nix-swarm-web
              ({ ... }: {
                boot.loader.grub.devices = [ "nodev" ];
                fileSystems."/" = {
                  device = "none";
                  fsType = "tmpfs";
                };
                system.stateVersion = "25.11";

                services.nix-swarm = {
                  enable = true;
                  package = pkgs.runCommand "nix-swarm-web-core-test-package" { } ''
                    mkdir -p "$out/bin"
                    touch "$out/bin/nix-swarmd"
                    chmod 0755 "$out/bin/nix-swarmd"
                  '';
                  nodeName = "nix-swarm@web.test";
                  cookieFile = "/run/keys/nix-swarm.cookie";
                  peers = [ "nix-swarm@web.test" ];
                  nodes."nix-swarm@web.test".deployHost = "root@web.test";
                };

                services.nix-swarm-web = {
                  enable = true;
                  package = webTestPackage;
                };
              })
            ];
          };

          webModuleEval =
            let
              disabled = webDisabledNode.config;
              baseline = webBaselineNode.config;
              enabled = webEnabledNode.config;
              service = enabled.systemd.services."nix-swarm-web";
              serviceConfig = service.serviceConfig;
              registration = enabled.services.nix-swarm.services."nix-swarm-web";
              environment = serviceConfig.Environment;
            in
            assert disabled.environment.systemPackages == baseline.environment.systemPackages;
            assert disabled.networking.firewall.allowedTCPPorts == baseline.networking.firewall.allowedTCPPorts;
            assert disabled.networking.firewall.interfaces == baseline.networking.firewall.interfaces;
            assert !(disabled.users.users ? "nix-swarm-web");
            assert !(disabled.systemd.services ? "nix-swarm-web");
            assert !(disabled.services.nix-swarm.services ? "nix-swarm-web");
            assert !(builtins.elem webTestPackage enabled.environment.systemPackages);
            assert enabled.networking.firewall.allowedTCPPorts == baseline.networking.firewall.allowedTCPPorts;
            assert enabled.networking.firewall.interfaces == baseline.networking.firewall.interfaces;
            assert serviceConfig.User == "nix-swarm-web";
            assert serviceConfig.Group == "nix-swarm-web";
            assert serviceConfig.SupplementaryGroups == [ "nix-swarm-operators" ];
            assert serviceConfig.Type == "simple";
            assert (service.wantedBy or [ ]) == [ ];
            assert builtins.elem "PHX_HOST=127.0.0.1" environment;
            assert builtins.elem "PORT=4000" environment;
            assert builtins.elem "NIX_SWARM_QUERY_SOCKET=/run/nix-swarm/query.sock" environment;
            assert builtins.elem "NIX_SWARM_POLL_INTERVAL_MS=5000" environment;
            assert serviceConfig.LoadCredential == [ ];
            assert serviceConfig.RuntimeDirectory == "nix-swarm-web";
            assert serviceConfig.RuntimeDirectoryMode == "0700";
            assert serviceConfig.UMask == "0077";
            assert serviceConfig.NoNewPrivileges;
            assert serviceConfig.PrivateTmp;
            assert serviceConfig.ProtectSystem == "strict";
            assert serviceConfig.ProtectHome;
            assert serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" "AF_INET" ];
            assert serviceConfig.CapabilityBoundingSet == "";
            assert serviceConfig.MemoryMax == "512M";
            assert serviceConfig.TasksMax == 256;
            assert serviceConfig.LimitNOFILE == 4096;
            assert !(serviceConfig ? StateDirectory);
            assert !(serviceConfig ? ReadWritePaths);
            assert registration.replicas == 1;
            assert registration.unitTemplate == "nix-swarm-web.service";
            assert registration.allowedNodes == [ ];
            assert registration.autoscaling.enable == false;
            assert registration.autoscaling.minReplicas == 1;
            assert registration.autoscaling.maxReplicas == 1;
            assert registration.state == null;
            pkgs.runCommand "nix-swarm-web-module-eval" { } ''
              grep -q SECRET_KEY_BASE_FILE ${serviceConfig.ExecStart}
              ! grep -Eq 'COOKIE|SSH|GIT|NIX_SWARM_SOURCE' ${serviceConfig.ExecStart}
              touch "$out"
            '';

          webVmTest = pkgs.testers.runNixOSTest {
            name = "nix-swarm-web";

            nodes.agent = { lib, ... }: {
              imports = [ self.nixosModules.nix-swarm-web ];
              networking.hostName = "web";

              users.users.operator = {
                isNormalUser = true;
                extraGroups = [ "nix-swarm-operators" ];
              };
              users.users.outsider.isNormalUser = true;

              services.nix-swarm = {
                enable = true;
                package = nixSwarm.cluster;
                nodeName = "nix-swarm@web";
                cookieFile = "/run/keys/nix-swarm.cookie";
                operatorUsers = [ "operator" ];
                peers = [ "nix-swarm@web" ];
                nodes."nix-swarm@web" = {
                  deployHost = "root@web";
                  nixosConfiguration = "web";
                };
              };

              services.nix-swarm-web = {
                enable = true;
                package = nixSwarmWeb.nix-swarm-web;
                port = 4000;
                pollIntervalMs = 500;
                allowedNodes = [ "nix-swarm@web" ];
              };

              systemd.tmpfiles.rules = [
                "d /run/keys 0700 root root -"
                "f+ /run/keys/nix-swarm.cookie 0400 root root - 0123456789abcdef0123456789abcdef"
              ];
            };

            testScript = ''
              agent.start()
              agent.wait_for_unit("nix-swarmd.service")
              agent.wait_until_succeeds("systemctl is-active nix-swarm-web.service", timeout=120)
              agent.wait_until_succeeds("curl --fail --silent --show-error http://127.0.0.1:4000/healthz | grep -q status", timeout=60)
              agent.wait_until_succeeds("curl --fail --silent --show-error http://127.0.0.1:4000/ | grep -q 'Cluster dashboard'", timeout=60)
              agent.succeed("runuser -u nix-swarm-web -- nix-swarm-query Y2x1c3Rlci1tZW1iZXJz > /tmp/web-query-output")
              agent.succeed("test -s /tmp/web-query-output")
              agent.succeed("runuser -u outsider -- test ! -r /run/nix-swarm/query.sock")
              agent.succeed("ss -ltn | awk '$4 ~ /:4000$/ && $4 !~ /^127\\.0\\.0\\.1:/ { exit 1 }'")
              agent.succeed("ss -ltn | grep -Eq '127\\.0\\.0\\.1:4000'")
            '';
          };

          testNode = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              ({ ... }: {
                boot.loader.grub.devices = [ "nodev" ];
                fileSystems."/" = {
                  device = "none";
                  fsType = "tmpfs";
                };
                system.stateVersion = "25.11";

                services.nix-swarm = {
                  enable = true;
                  package = nixSwarm.cluster;
                  nodeName = "nix-swarm@node-a.test";
                  cookieFile = "/run/keys/nix-swarm.cookie";
                  peers = [ "nix-swarm@node-a.test" ];
                  nodes."nix-swarm@node-a.test" = {
                    deployHost = "root@node-a.test";
                  };
                  services.example.unitTemplate = "example.service";
                };
              })
            ];
          };

          exampleNodeA = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [ ./examples/config/machines/example-node-a.nix ];
          };

          exampleNodeB = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [ ./examples/config/machines/example-node-b.nix ];
          };

          exampleConfigCaddy =
            assert exampleNodeA.config.services.caddy.enable;
            assert !exampleNodeB.config.services.caddy.enable;
            assert exampleNodeA.config.services.nix-swarm.services.caddy.unitTemplate == "caddy.service";
            assert exampleNodeA.config.services.nix-swarm.services.caddy.allowedNodes == [ "nix-swarm@example-node-a.local" ];
            assert exampleNodeA.config.systemd.services ? caddy;
            pkgs.runCommand "nix-swarm-example-caddy-config" { } ''
              touch "$out"
            '';

          caddyVmTest = pkgs.testers.runNixOSTest {
            name = "nix-swarm-caddy-edge";

            nodes.edge = { lib, pkgs, ... }: {
              imports = [ self.nixosModules.default ];
              networking.hostName = "edge";

              services.nix-swarm = {
                enable = true;
                package = nixSwarm.cluster;
                nodeName = "nix-swarm@edge";
                cookieFile = "/run/keys/nix-swarm.cookie";
                peers = [ "nix-swarm@edge" ];
                nodes."nix-swarm@edge" = {
                  deployHost = "root@edge";
                };
                services = {
                  caddy = {
                    replicas = 1;
                    unitTemplate = "caddy.service";
                    allowedNodes = [ "nix-swarm@edge" ];
                  };
                  example = {
                    replicas = 1;
                    unitTemplate = "example.service";
                    allowedNodes = [ "nix-swarm@edge" ];
                  };
                };
              };

              services.caddy = {
                enable = true;
                virtualHosts."http://app.test".extraConfig = ''
                  reverse_proxy 127.0.0.1:8080 127.0.0.1:8081 {
                    health_uri /
                    health_interval 1s
                    health_timeout 500ms
                    fail_duration 2s
                  }
                '';
              };

              systemd.tmpfiles.rules = [
                "d /run/keys 0700 root root -"
                "f+ /run/keys/nix-swarm.cookie 0400 root root - 0123456789abcdef0123456789abcdef"
              ];

              systemd.services.example = {
                wantedBy = lib.mkForce [ ];
                serviceConfig = {
                  ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080 --bind 127.0.0.1";
                  Restart = "always";
                };
              };

              systemd.services.example-secondary = {
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                  ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8081 --bind 127.0.0.1";
                  Restart = "no";
                };
              };
            };

            testScript = ''
              edge.start()
              edge.wait_for_unit("nix-swarmd.service")
              edge.wait_for_unit("caddy.service")
              edge.wait_until_succeeds("systemctl is-active example.service")
              edge.wait_until_succeeds("systemctl is-active example-secondary.service")
              edge.succeed("systemctl is-enabled caddy.service")
              edge.succeed("curl --fail --silent --show-error -H 'Host: app.test' http://127.0.0.1/ | grep -q '<title>Directory listing for /</title>'")
              edge.succeed("systemctl stop example-secondary.service")
              edge.succeed("sleep 3; timeout 5 curl --fail --silent --show-error -H 'Host: app.test' http://127.0.0.1/ | grep -q '<title>Directory listing for /</title>'")
              edge.succeed("test ! -e /run/nix-swarm/Caddyfile && test ! -e /var/lib/nix-swarm/Caddyfile")
            '';
          };

          vmTest = pkgs.testers.runNixOSTest {
            name = "nix-swarm-agent";

            nodes.agent = { lib, pkgs, ... }: {
              imports = [ self.nixosModules.default ];
              networking.hostName = "node";

              users.users.operator = {
                isNormalUser = true;
                extraGroups = [ "nix-swarm-operators" ];
              };
              users.users.outsider.isNormalUser = true;

              services.nix-swarm = {
                enable = true;
                package = nixSwarm.cluster;
                nodeName = "nix-swarm@node";
                cookieFile = "/run/keys/nix-swarm.cookie";
                peers = [ "nix-swarm@node" ];
                nodes."nix-swarm@node" = {
                  deployHost = "root@node";
                  nixosConfiguration = "node";
                };
                services.demo = {
                  replicas = 1;
                  unitTemplate = "demo.service";
                };
              };

              systemd.tmpfiles.rules = [
                "d /run/keys 0700 root root -"
                "f+ /run/keys/nix-swarm.cookie 0400 root root - 0123456789abcdef0123456789abcdef"
              ];

              systemd.services.demo = {
                wantedBy = lib.mkForce [ ];
                serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
              };
            };

            testScript = ''
              agent.start()
              agent.wait_for_unit("nix-swarmd.service")
              agent.wait_until_succeeds("systemctl is-active demo.service")
              agent.succeed("systemctl show nix-swarmd.service -p Type --value | grep -x notify")
              agent.succeed("systemctl show nix-swarmd.service -p User --value | grep -x nix-swarm")
              agent.succeed("! tr '\\0' ' ' </proc/$(systemctl show nix-swarmd.service -p MainPID --value)/cmdline | grep -q 0123456789abcdef")
              agent.succeed("tr '\\0' '\\n' </proc/$(systemctl show nix-swarmd.service -p MainPID --value)/environ | grep -q '^ERL_AFLAGS=.*net_ticktime 10.*'")
              agent.succeed("test $(stat -c %a /run/nix-swarm/beam/.erlang.cookie) = 400")
              agent.succeed("test -S /run/nix-swarm/query.sock")
              agent.succeed("runuser -u operator -- nix-swarm-query Y2x1c3Rlci1tZW1iZXJz > /tmp/query-output && test -s /tmp/query-output")
              agent.succeed("runuser -u outsider -- test ! -r /run/nix-swarm/query.sock")
              agent.succeed("test -f /var/lib/nix-swarm/nix-swarm_node/operational-state.dets")
            '';
          };

          starterSyntax =
            assert builtins.isAttrs (import ./examples/starter/flake.nix);
            assert builtins.isFunction (import ./examples/starter/cluster.nix);
            assert builtins.isFunction (import ./examples/starter/machines/node-a.nix);
            assert builtins.isFunction (import ./examples/starter/profiles/nix-swarm-node.nix);
            assert builtins.isFunction (import ./examples/starter/services/example-web.nix);
            assert !(builtins.pathExists ./examples/starter/disko);
            assert !(builtins.pathExists ./examples/starter/machines/node-c);
            pkgs.runCommand "nix-swarm-starter-syntax" { } ''
              touch "$out"
            '';

          planFixture = pkgs.writeTextDir "flake.nix" ''
            {
              inputs.fixture.url = "path:${pkgs.path}";

              outputs = { fixture, ... }:
                {
                  nixosConfigurations.node-a.config.system.build.toplevel = fixture.outPath;
                  lib.nixSwarm.deploymentManifest = {
                    schemaVersion = 1;
                    nodes."nix-swarm@node-a.test" = {
                      availability = "active";
                      deployHost = "root@node-a.test";
                      nixosConfiguration = "node-a";
                    };

                  };
                };
            }
          '';

          operatorSmoke = pkgs.runCommand "nix-swarm-operator-smoke"
            {
              nativeBuildInputs = [ pkgs.nix ];
            } ''
            set -eu
            export HOME="$TMPDIR/home"
            export NIX_SWARM_SOURCE="$TMPDIR/config"
            export NIX_CONFIG="experimental-features = nix-command flakes"
            export ELIXIR_ERL_OPTIONS="+fnu"
            mkdir -p "$HOME"
            mkdir -p "$TMPDIR/config"
            cp ${planFixture}/flake.nix "$TMPDIR/config/flake.nix"
            ${nixSwarm.operator}/bin/nix-swarm --help > "$TMPDIR/help"
            test -z "$(find "$TMPDIR/config" -mindepth 1 -not -name flake.nix -print -quit)" || {
              echo "nix-swarm --help created files under NIX_SWARM_SOURCE:"
              find "$TMPDIR/config" -mindepth 1 -not -name flake.nix
              exit 1
            }
            ${nixSwarm.operator}/bin/nix-swarm --version > "$TMPDIR/version"
            ${nixSwarm.operator}/bin/nix-swarm cluster plan --source "$TMPDIR/config" > "$TMPDIR/plan"
            grep -qi "read-only operator TUI" "$TMPDIR/help" || {
              cat "$TMPDIR/help"
              exit 1
            }
            grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' "$TMPDIR/version" || {
              cat "$TMPDIR/version"
              exit 1
            }
            test "$(wc -l < "$TMPDIR/version")" -eq 1 || {
              echo "nix-swarm --version must print exactly one line:"
              cat "$TMPDIR/version"
              exit 1
            }
            grep -q "NixOS deployment plan" "$TMPDIR/plan" || {
              cat "$TMPDIR/plan"
              exit 1
            }
            grep -q "nixos-rebuild" "$TMPDIR/plan" || {
              cat "$TMPDIR/plan"
              exit 1
            }
            touch "$out"
          '';
        in
        {
          operator-package = nixSwarm.operator;
          agent-package = nixSwarm.cluster;
          web-module = webModuleEval;
          web-vm = webVmTest;
          nixos-module = testNode.config.system.build.toplevel;
          nixos-vm = vmTest;
          caddy-vm = caddyVmTest;
          starter-syntax = starterSyntax;
          operator-smoke = operatorSmoke;
          example-config-caddy = exampleConfigCaddy;
        });

      nixosModules = {
        nix-swarm = import ./nix/nix-swarm/module.nix;
        nix-swarm-web = import ./nix/nix-swarm-web/module.nix;
        default = self.nixosModules.nix-swarm;
        hardened = {
          imports = [ self.nixosModules.nix-swarm ];
          services.nix-swarm.hardened = true;
        };
      };
    };
}
