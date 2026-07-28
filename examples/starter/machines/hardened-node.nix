{ ... }:

let
  # Copy this file once per machine and change the identity values below.
  hostname = "node-a";
  swarmNode = "nix-swarm@node-a";
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  # Keep this equal to the original NixOS release on the machine. It is not
  # the release you are currently upgrading to.
  system.stateVersion = "26.05";
  networking.hostName = hostname;

  # Do not deploy until this is replaced with a real, pre-distributed key.
  # Keep the private key off the node and out of the Nix source tree.
  users.mutableUsers = false;
  users.users.root = {
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 REPLACE_WITH_YOUR_DEPLOYMENT_PUBLIC_KEY nix-swarm-deployer"
    ];
  };

  # The node needs SSH for Nix-Swarm deployment and read-only operator queries.
  # Add declared operator users here and to services.nix-swarm.operatorUsers.
  services.openssh = {
    enable = true;
    allowSFTP = false;
    settings = {
      AllowAgentForwarding = false;
      AllowTcpForwarding = "no";
      AllowUsers = [ "root" ];
      ClientAliveCountMax = 2;
      ClientAliveInterval = 300;
      KbdInteractiveAuthentication = false;
      LoginGraceTime = 20;
      MaxAuthTries = 3;
      MaxSessions = 4;
      PasswordAuthentication = false;
      PermitEmptyPasswords = false;
      PermitRootLogin = "prohibit-password";
      PubkeyAuthentication = true;
      X11Forwarding = false;
    };
  };

  # Keep peer traffic off the host/LAN interfaces. Configure wg0 (or replace
  # it with the private Tailscale/WireGuard interface used by the cluster).
  networking.firewall = {
    enable = true;
    allowPing = false;
    logRefusedConnections = true;
    allowedTCPPorts = [ 22 ];
  };

  services.nix-swarm = {
    enable = true;
    nodeName = swarmNode;
    cookieFile = "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie";
    operatorUsers = [ ];
    openFirewall = true;
    firewallInterfaces = [ "wg0" ];

    hardened = true;

    # These are intentionally tighter than the module defaults. Increase
    # them only after measuring a real workload and recording the reason.
    resourceLimits = {
      memoryMax = "384M";
      tasksMax = 256;
    };

    runtime = {
      connectIntervalMs = 1000;
      reconcileIntervalMs = 5000;
      autoscaleIntervalMs = 15000;
      failureGraceMs = 15000;
      recoveryStabilizationMs = 30000;
      commandTimeoutMs = 5000;
      generation = "hardened-node";
    };

    deployment = {
      healthTimeoutSec = 120;
      stableSamples = 3;
      autoRollback = true;
    };
  };

}
