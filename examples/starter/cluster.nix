{ ... }:
{
  services.nix-swarm = {
    peers = [ "nix-swarm@node-a" ];

    nodes."nix-swarm@node-a" = {
      availability = "active";
      deployHost = "root@node-a";
      nixosConfiguration = "node-a";
    };

  };
}
