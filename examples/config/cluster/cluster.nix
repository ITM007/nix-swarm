{ ... }:
{
  imports = [
    ./services/example-web.nix
  ];

  services.nix-swarm = {
    peers = [
      "nix-swarm@example-node-a.local"
      "nix-swarm@example-node-b.local"
    ];

    nodes = {
      "nix-swarm@example-node-a.local" = {
        labels = [ "ingress" "apps" ];
        deployHost = "root@example-node-a.local";
        nixosConfiguration = "example-node-a";
      };

      "nix-swarm@example-node-b.local" = {
        labels = [ "apps" ];
        deployHost = "root@example-node-b.local";
        nixosConfiguration = "example-node-b";
      };
    };

    services = {
      example-web = {
        replicas = 2;
        preferredNodes = [
          "nix-swarm@example-node-a.local"
          "nix-swarm@example-node-b.local"
        ];
        settings = {
          docs = "Replace this example service with your own unit definitions.";
        };
      };
    };

    ingress.sites.example-web = {
      domain = "example.internal";
      service = "example-web";
      basePort = 8080;
      default = true;
    };
  };
}
