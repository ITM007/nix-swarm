{ ... }:
{
  services.nix-swarm = {
    peers = [ "nix-swarm@node-c" ];

    nodes."nix-swarm@node-c" = {
      labels = [ "apps" ];
      availability = "active";
      deployHost = "root@node-c";
      nixosConfiguration = "node-c";
    };
  };
}
