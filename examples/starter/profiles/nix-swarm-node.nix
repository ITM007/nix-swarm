{ config, lib, pkgs, ... }:

let
  cfg = config.services.nix-swarm;
  privateInterfaces = cfg.firewallInterfaces;
in
{
  assertions = [
    {
      assertion = builtins.all
        (key: key != "REPLACE_WITH_YOUR_DEPLOYMENT_PUBLIC_KEY nix-swarm-deployer")
        (config.users.users.root.openssh.authorizedKeys.keys or [ ]);
      message = "Replace the deployment SSH public-key placeholder in the machine configuration before evaluating a node.";
    }
    {
      assertion = lib.hasPrefix "/" cfg.cookieFile && !lib.hasPrefix "/nix/store/" cfg.cookieFile;
      message = "Nix-Swarm cookieFile must be an absolute path outside /nix/store.";
    }
    {
      assertion = !cfg.openFirewall || privateInterfaces != [ ];
      message = "Nix-Swarm peer firewall access requires an explicitly declared private interface.";
    }
  ];

  nixpkgs.config.allowUnfree = false;

  services.nix-swarm = {
    enable = true;
    hardened = true;
    resourceLimits = {
      memoryMax = "384M";
      tasksMax = 256;
    };
    openFirewall = lib.mkDefault false;
    firewallInterfaces = lib.mkDefault [ ];
    cookieFile = "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie";
  };

  networking.firewall = {
    enable = lib.mkDefault true;
    allowPing = lib.mkDefault false;
  };

  services.openssh.settings = {
    AllowUsers = lib.mkDefault [ "root" ];
    PermitRootLogin = lib.mkDefault "prohibit-password";
  };

}
