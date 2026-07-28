{ inputs, ... }:
{
  imports = [
    ../../profiles/nix-swarm-node.nix
    ./disko.nix
  ];

  # Replace every value marked REPLACE before evaluating this target.
  networking.hostName = "node-c";
  system.stateVersion = "26.05";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  users.users.root = {
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [
      "REPLACE_WITH_YOUR_DEPLOYMENT_PUBLIC_KEY nix-swarm-deployer"
    ];
  };

  services.openssh.settings.AllowUsers = [ "root" ];

  services.nix-swarm = {
    nodeName = "nix-swarm@node-c";
    peers = [ "nix-swarm@node-c" ];
    nodes."nix-swarm@node-c" = {
      labels = [ "apps" ];
      availability = "active";
      deployHost = "root@node-c";
      nixosConfiguration = "node-c";
    };
    firewallInterfaces = [ "wg0" ];
    openFirewall = true;
  };
}
