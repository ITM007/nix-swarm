{ ... }:
{
  imports = [
    ../nix/nix-swarm/module.nix
    ../cluster/cluster.nix
    ../services/caddy-edge.nix
  ];

  services.nix-swarm = {
    enable = true;
    nodeName = "nix-swarm@example-node-a.local";
    cookieFile = "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie";
    openFirewall = true;
    # Example only: netbird0 is the optional overlay variant; on a trusted
    # LAN name the actual LAN interface instead (see docs/INGRESS.md).
    firewallInterfaces = [ "netbird0" ];
  };

  networking.firewall.interfaces.netbird0.allowedTCPPorts = [ 8080 8081 ];
}
