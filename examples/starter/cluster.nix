{ ... }:
{
  services.nix-swarm = {
    peers = [ "nix-swarm@node-a" ];

    nodes."nix-swarm@node-a" = {
      availability = "active";
      deployHost = "root@node-a";
      nixosConfiguration = "node-a";
    };

    services.example-web = {
      replicas = 1;
      unitTemplate = "example-web.service";
      allowedNodes = [ "nix-swarm@node-a" ];
    };

    services.caddy = {
      replicas = 1;
      unitTemplate = "caddy.service";
      allowedNodes = [ "nix-swarm@node-a" ];
    };
  };
}
