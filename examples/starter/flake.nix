{
  description = "A minimal Nix-Swarm cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-swarm.url = "github:ITM007/nix-swarm";
    nix-swarm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ nixpkgs, nix-swarm, ... }:
    let
      mkNode = machine:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = [
            nix-swarm.nixosModules.default
            ./cluster.nix
            machine
          ];
        };

      nixosConfigurations = {
        node-a = mkNode ./machines/node-a.nix;
        node-a-hardened = mkNode ./machines/hardened-node.nix;
      };
    in
    {
      inherit nixosConfigurations;
      lib.nixSwarm.deploymentManifest = {
        schemaVersion = 1;
        nodes."nix-swarm@node-a" = {
          availability = "active";
          deployHost = "root@node-a";
          nixosConfiguration = "node-a";
        };
        deployment = {
          healthTimeoutSec = 120;
          stableSamples = 2;
          autoRollback = true;
        };
      };
    };
}
