{ config, lib, pkgs, ... }:

let
  cfg = config.services.nix-swarm-web;
  swarm = config.services.nix-swarm;
  inherit (lib) all hasPrefix hasInfix mkEnableOption mkForce mkIf mkOption types;

  webStart = pkgs.writeShellScript "nix-swarm-web-start" ''
    set -eu

    secret_file="$RUNTIME_DIRECTORY/secret-key-base"
    umask 0077
    ${pkgs.openssl}/bin/openssl rand -hex 64 > "$secret_file"
    chmod 0400 "$secret_file"

    export HOME="$RUNTIME_DIRECTORY"
    export SECRET_KEY_BASE_FILE="$secret_file"
    exec ${cfg.package}/bin/nix-swarm-web start
  '';

  validSocketPath =
    hasPrefix "/" cfg.querySocket
    && !(hasPrefix "/nix/store/" cfg.querySocket)
    && !(hasInfix "\n" cfg.querySocket)
    && !(hasInfix "\r" cfg.querySocket);

  webServiceRegistration = {
    replicas = mkForce 1;
    unitTemplate = mkForce "nix-swarm-web.service";
    allowedNodes = mkForce cfg.allowedNodes;
    autoscaling = {
      enable = mkForce false;
      minReplicas = mkForce 1;
      maxReplicas = mkForce 1;
    };
    state = mkForce null;
  };
in
{
  imports = [ ../nix-swarm/module.nix ];

  options.services.nix-swarm-web = {
    enable = mkEnableOption "the separate read-only Nix-Swarm web release";

    package = mkOption {
      type = types.package;
      default = (import ./packages.nix { inherit pkgs; }).nix-swarm-web;
      description = "Separate Phoenix/LiveView/Bandit release for the read-only web UI.";
    };

    port = mkOption {
      type = types.port;
      default = 4000;
      description = "Loopback-only TCP port for the read-only web UI.";
    };

    querySocket = mkOption {
      type = types.str;
      default = "/run/nix-swarm/query.sock";
      description = "Local Nix-Swarm query socket consumed by the read-only web UI.";
    };

    pollIntervalMs = mkOption {
      type = types.ints.between 500 3600000;
      default = 5000;
      description = "Interval between bounded read-only snapshot refreshes, in milliseconds.";
    };

    allowedNodes = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Optional hard allowlist for the single cluster-managed web replica; empty means all eligible nodes.";
    };

    writeMode.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Reserved for the separately reviewed write-mode release; Release 1 is read-only.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = swarm.enable;
        message = "services.nix-swarm-web.enable requires services.nix-swarm.enable for the local query socket and cluster service registration";
      }
      {
        assertion = !cfg.writeMode.enable;
        message = "services.nix-swarm-web.writeMode.enable is reserved for the write-mode release";
      }
      {
        assertion = validSocketPath;
        message = "services.nix-swarm-web.querySocket must be an absolute, out-of-store path without newlines";
      }
      {
        assertion = all (node: lib.elem node swarm.peers) cfg.allowedNodes;
        message = "services.nix-swarm-web.allowedNodes must reference configured Nix-Swarm peers";
      }
    ];

    users.groups.nix-swarm-web = { };
    users.users.nix-swarm-web = {
      isSystemUser = true;
      group = "nix-swarm-web";
      extraGroups = [ swarm.operatorGroup ];
    };

    systemd.services.nix-swarm-web = {
      description = "Nix-Swarm read-only web UI";
      after = [ "nix-swarmd.service" ];

      serviceConfig = {
        User = "nix-swarm-web";
        Group = "nix-swarm-web";
        SupplementaryGroups = [ swarm.operatorGroup ];
        Type = "simple";
        Environment = [
          "PHX_SERVER=true"
          "PHX_HOST=127.0.0.1"
          "PORT=${toString cfg.port}"
          "NIX_SWARM_QUERY_SOCKET=${cfg.querySocket}"
          "NIX_SWARM_POLL_INTERVAL_MS=${toString cfg.pollIntervalMs}"
        ];
        # The read-only release has no BEAM cookie, SSH key, or write secret.
        LoadCredential = [ ];
        ExecStart = webStart;
        Restart = "on-failure";
        RestartSec = 2;
        RuntimeDirectory = "nix-swarm-web";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
        CapabilityBoundingSet = "";
        MemoryMax = "512M";
        TasksMax = 256;
        LimitNOFILE = 4096;
        SystemCallArchitectures = "native";
      };
    };

    # The web unit is deliberately not wanted by any target. The core
    # reconciler starts exactly one replica on an eligible node.
    services.nix-swarm.services.nix-swarm-web = webServiceRegistration;
  };
}
