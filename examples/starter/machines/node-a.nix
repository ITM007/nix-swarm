{ ... }:
{
  # Generate this file from the real host before the first deployment:
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "node-a";
  system.stateVersion = "26.05"; # Set this to the host's original NixOS release.

  services.nix-swarm = {
    enable = true;
    nodeName = "nix-swarm@node-a";
    cookieFile = "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie";

    # Root can use the query socket. Add existing non-root SSH users here.
    operatorUsers = [ ];

    # A one-node cluster needs no BEAM firewall ports. For multiple nodes,
    # open them only on a private WireGuard/Tailscale interface.
    openFirewall = false;
  };
}
