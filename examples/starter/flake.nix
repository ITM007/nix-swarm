{
  description = "A prepared NixOS machine running a minimal Nix-Swarm service";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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
        node-a = mkNode {
          machine = ./machines/node-a.nix;
        };
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

      };
    };
}
