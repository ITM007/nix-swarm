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
          deployment = if enabled == [ ] then { } else (builtins.head enabled).config.services.nix-swarm.deployment;
        in
        {
          schemaVersion = 1;
          nodes = mergedNodes;
          inherit deployment;
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
        deployment = {
          healthTimeoutSec = 120;
          stableSamples = 2;
          autoRollback = true;
        };
      };

      packages = forAllSystems (_system: pkgs:
        let
          nixSwarm = import ./nix/nix-swarm/packages.nix { inherit pkgs; };
        in
        {
          default = nixSwarm.combined;
          nix-swarm = nixSwarm.combined;
          operator = nixSwarm.operator;
          cluster = nixSwarm.cluster;
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
                    labels = [ "test" ];
                    deployHost = "root@node-a.test";
                  };
                  services.example.unitTemplate = "example.service";
                };
              })
            ];
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
                  labels = [ "test" ];
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
            assert builtins.isFunction (import ./examples/starter/services/example-web.nix);
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
                    deployment = {
                      healthTimeoutSec = 120;
                      stableSamples = 2;
                      autoRollback = true;
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
            ${nixSwarm.operator}/bin/nix-swarm --version > "$TMPDIR/version"
            ${nixSwarm.operator}/bin/nix-swarm cluster plan --source "$TMPDIR/config" > "$TMPDIR/plan"
            grep -q "read-only operator TUI" "$TMPDIR/help" || {
              cat "$TMPDIR/help"
              exit 1
            }
            grep -Eq 'v?[0-9]+\.[0-9]+\.[0-9]+' "$TMPDIR/version" || {
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
          nixos-module = testNode.config.system.build.toplevel;
          nixos-vm = vmTest;
          starter-syntax = starterSyntax;
          operator-smoke = operatorSmoke;
        });

      nixosModules = {
        nix-swarm = import ./nix/nix-swarm/module.nix;
        default = self.nixosModules.nix-swarm;
      };
    };
}
