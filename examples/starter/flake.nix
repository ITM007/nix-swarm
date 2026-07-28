{
  description = "A minimal hardened Nix-Swarm cluster and nixos-anywhere starter";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    nix-swarm.url = "github:ITM007/nix-swarm";
    nix-swarm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ nixpkgs, nix-swarm, ... }:
    let
      mkNode = { machine, cluster ? ./cluster.nix }:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = [
            nix-swarm.nixosModules.hardened
            cluster
            machine
          ];
        };

      nixosConfigurations = {
        # Copy machines/node-c and replace its explicit disk/key/interface
        # values before using this target with nixos-anywhere.
        node-c = mkNode {
          machine = ./machines/node-c/default.nix;
        };
      };
    in
    {
      inherit nixosConfigurations;

      lib.nixSwarm.deploymentManifest = {
        schemaVersion = 1;
        nodes."nix-swarm@node-c" = {
          availability = "active";
          deployHost = "root@node-c";
          nixosConfiguration = "node-c";
        };
        deployment = {
          canaryNodes = [ "nix-swarm@node-c" ];
          maxUnavailable = 1;
          healthTimeoutSec = 180;
          stableSamples = 3;
          autoRollback = true;
        };
      };
    };
}
