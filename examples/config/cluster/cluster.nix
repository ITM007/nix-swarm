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
        deployHost = "example-node-a.local";
      };

      "nix-swarm@example-node-b.local" = {
        labels = [ "apps" ];
        deployHost = "example-node-b.local";
      };
    };

    services = {
      example-web = {
        replicas = 2;
        preferredNodes = [
          "nix-swarm@example-node-a.local"
          "nix-swarm@example-node-b.local"
        ];
        healthcheck = "curl -fsS http://127.0.0.1:8080/health || exit 1";
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
