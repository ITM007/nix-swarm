{ ... }:
{
  imports = [ ./services/example-web.nix ];

  services.nix-swarm = {
    peers = [ "nix-swarm@node-a" ];

    nodes."nix-swarm@node-a" = {
      labels = [ "apps" ];
      deployHost = "root@node-a";
      nixosConfiguration = "node-a";
    };

    services = {
      example-web = {
        replicas = 1;
        constraints = [ "apps" ];
        settings.port = 8080;
      };
    };
  };
}
