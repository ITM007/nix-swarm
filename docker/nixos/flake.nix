{
  description = "NixOS systemd containers for the Nix-Swarm integration harness";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-swarm = {
      url = "path:../..";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nix-swarm, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = import nixpkgs { inherit system; };
      clusterPackage = nix-swarm.packages.${system}.cluster;
      operatorPackage = nix-swarm.packages.${system}.operator;
      peerNames = [
        "nix-swarm@node-a"
        "nix-swarm@node-b"
        "nix-swarm@node-c"
      ];

      nodeMetadata = builtins.listToAttrs (map
        (nodeName:
          let
            hostname = lib.removePrefix "nix-swarm@" nodeName;
          in
          {
            name = nodeName;
            value = {
              labels = [ "docker" "integration" ] ++ lib.optional (hostname == "node-a") "ingress";
              availability = "active";
              deployHost = "root@${hostname}";
              nixosConfiguration = hostname;
            };
          })
        peerNames);

      mkNode = { nodeName, hostname }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            nix-swarm.nixosModules.default
            ({ config, lib, pkgs, ... }:
              let
                operatorCommand = pkgs.writeShellScriptBin "nixos-operator-command" ''
                  export IN_NIXOS_SYSTEMD_STAGE1=true
                  /run/current-system/init

                  ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root /root/.ssh
                  if [ -r /etc/nix-swarm-authorized_keys ]; then
                    ${pkgs.coreutils}/bin/install -m 0600 -o root -g root /etc/nix-swarm-authorized_keys /root/.ssh/authorized_keys
                  fi
                  if [ -r /etc/nix-swarm-operator-key ]; then
                    ${pkgs.coreutils}/bin/install -m 0600 -o root -g root /etc/nix-swarm-operator-key /root/.ssh/id_ed25519
                  fi
                  exec "$@"
                '';
              in
              {
                boot.isContainer = true;
                system.stateVersion = "25.11";
                networking.hostName = hostname;
                networking.firewall.enable = false;

                environment.systemPackages = [ operatorPackage operatorCommand ];
                environment.pathsToLink = [ "/share/nix-swarm" ];
                environment.etc."nix-swarm-demo/index.html".text = ''
                  Nix-Swarm Docker integration harness: ${hostname}
                '';

                systemd.tmpfiles.rules = [
                  "d /root/.ssh 0700 root root -"
                  "d /run/keys 0700 root root -"
                ];

                services.openssh = {
                  enable = true;
                  settings = {
                    PasswordAuthentication = false;
                    KbdInteractiveAuthentication = false;
                    PermitRootLogin = "prohibit-password";
                  };
                };

                systemd.services.nix-swarm-docker-credentials = {
                  description = "Install Docker integration credentials for Nix-Swarm";
                  before = [ "nix-swarmd.service" ];
                  wantedBy = [ "nix-swarmd.service" ];
                  serviceConfig = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                  };
                  script = ''
                    ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root /root/.ssh
                    if [ -r /etc/nix-swarm-cookie-source ]; then
                      ${pkgs.coreutils}/bin/install -m 0400 -o root -g root /etc/nix-swarm-cookie-source /etc/nix-swarm.cookie
                    fi
                    if [ -r /etc/nix-swarm-authorized_keys ]; then
                      ${pkgs.coreutils}/bin/install -m 0600 -o root -g root /etc/nix-swarm-authorized_keys /root/.ssh/authorized_keys
                    fi
                  '';
                };

                systemd.services."demo@" = {
                  description = "Nix-Swarm managed HTTP demo (%i)";
                  wantedBy = lib.mkForce [ ];
                  serviceConfig = {
                    ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /etc/nix-swarm-demo";
                    Restart = "on-failure";
                    RestartSec = 1;
                    DynamicUser = true;
                    NoNewPrivileges = true;
                    PrivateTmp = true;
                    ProtectHome = true;
                    ProtectSystem = "strict";
                    ReadWritePaths = [ "/run" ];
                  };
                };

                services.nix-swarm = {
                  enable = true;
                  package = clusterPackage;
                  nodeName = nodeName;
                  cookieFile = "/etc/nix-swarm.cookie";
                  peers = peerNames;
                  nodes = nodeMetadata;

                  services.demo = {
                    replicas = 3;
                    maxReplicasPerNode = 1;
                    unitTemplate = "demo@%{slot}.service";
                    preferredNodes = peerNames;
                    readiness = {
                      timeoutSec = 30;
                      stableSamples = 2;
                    };
                    settings = {
                      description = "Three-node Docker/systemd integration workload";
                      portBase = 8080;
                    };
                  };
                };
              })
          ];
        };

      mkImage = { nodeName, hostname }:
        let
          machine = mkNode { inherit nodeName hostname; };
          entrypoint = pkgs.writeShellScript "nixos-docker-entrypoint-${hostname}" ''
            ${pkgs.coreutils}/bin/mkdir -p /run
            ${pkgs.coreutils}/bin/ln -sfn ${machine.config.system.build.toplevel} /run/current-system

            if [ "$#" -eq 0 ]; then
              set -- ${machine.config.system.build.toplevel}/init
            fi

            exec "$@"
          '';
        in
        pkgs.dockerTools.buildLayeredImage {
          name = "nix-swarm/nixos-${hostname}";
          tag = "dev";
          contents = [ machine.config.system.build.toplevel ];
          extraCommands = ''
            if [ -L etc ]; then
              rm etc
            fi
            mkdir -p etc
            cp -a ${machine.config.system.build.toplevel}/etc/. etc/
            mkdir -p root/.ssh
          '';
          config = {
            Entrypoint = [ entrypoint ];
            Cmd = [ "${machine.config.system.build.toplevel}/init" ];
            Env = [
              "PATH=/run/current-system/sw/bin:/bin:/usr/bin"
              "container=docker"
            ];
            WorkingDir = "/";
            StopSignal = "SIGRTMIN+3";
          };
        };
    in
    {
      packages.${system} = {
        node-a = mkImage {
          nodeName = "nix-swarm@node-a";
          hostname = "node-a";
        };
        node-b = mkImage {
          nodeName = "nix-swarm@node-b";
          hostname = "node-b";
        };
        node-c = mkImage {
          nodeName = "nix-swarm@node-c";
          hostname = "node-c";
        };
      };
    };
}
