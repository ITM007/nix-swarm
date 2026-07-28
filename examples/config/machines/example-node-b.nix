{ ... }:
{
  imports = [
    ../nix/nix-swarm/module.nix
    ../cluster/cluster.nix
  ];

  services.nix-swarm = {
    enable = true;
    nodeName = "nix-swarm@example-node-b.local";
    cookieFile = "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie";
    openFirewall = true;
    # Example only: replace wg0 with your private overlay interface.
    firewallInterfaces = [ "wg0" ];
  };
}
