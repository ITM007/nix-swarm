{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../profiles/nix-swarm-node.nix
    ../services/example-web.nix
  ];

  networking.hostName = "node-a";
  system.stateVersion = "26.05"; # Set this to the host's original NixOS release.

  users.users.root = {
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [
      "REPLACE_WITH_YOUR_DEPLOYMENT_PUBLIC_KEY nix-swarm-deployer"
    ];
  };

  services.openssh.enable = true;

  services.nix-swarm = {
    nodeName = "nix-swarm@node-a";
    cookieFile = "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie";

    # Root can use the query socket. Add existing non-root SSH users here.
    operatorUsers = [ ];

    # A one-node cluster needs no BEAM firewall ports. For multiple nodes,
    # open them only on a private WireGuard/Tailscale interface.
    openFirewall = false;
  };
}
