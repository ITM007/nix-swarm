{ config, pkgs, lib, modulesPath, ... }:
{
  imports = [ ../cluster.nix ];

  services.nix-swarm = {
    nodeName = "node-a@cluster";
    openFirewall = true;
    firewallInterfaces = [ "eth0" ];
  };
}
