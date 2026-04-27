{ ... }:
{
  imports = [
    ../nix/nix-swarm/module.nix
    ../cluster/cluster.nix
  ];

  services.nix-swarm = {
    enable = true;
    nodeName = "nix-swarm@example-node-a.local";
    cookieFile = "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie";
    openFirewall = true;
    firewallInterfaces = [ "eth0" ];
  };
}
