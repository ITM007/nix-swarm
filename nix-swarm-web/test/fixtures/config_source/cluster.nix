# Shared cluster-level configuration used by the fixture test source.

{ config, lib, ... }:
{
  # One-line fixture comment for syntax highlighting coverage.
  services.nix-swarm = {
    peers = [ "nix-swarm@node-a" "nix-swarm@node-b" ];

    nodes."nix-swarm@node-a" = {
      availability = "active";
      deployHost = "root@node-a";
      nixosConfiguration = "node-a";
    };

    services = {
      api = {
        replicas = 1;
        unitTemplate = "api.service";
        allowedNodes = [ "nix-swarm@node-a" ];
      };
    };
  };
}
