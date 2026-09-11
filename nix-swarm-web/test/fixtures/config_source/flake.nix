{
  description = "Fixture cluster flake";

  outputs = { self, nixpkgs }:
    {
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
