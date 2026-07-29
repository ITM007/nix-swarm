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
        deployHost = "root@example-node-a.local";
        nixosConfiguration = "example-node-a";
      };

      "nix-swarm@example-node-b.local" = {
        deployHost = "root@example-node-b.local";
        nixosConfiguration = "example-node-b";
      };
    };

    services = {
      example-web = {
        replicas = 2;
        unitTemplate = "example-web@%{slot}.service";
        allowedNodes = [
          "nix-swarm@example-node-a.local"
          "nix-swarm@example-node-b.local"
        ];
      };

      caddy = {
        replicas = 1;
        unitTemplate = "caddy.service";
        allowedNodes = [ "nix-swarm@example-node-a.local" ];
      };
    };
  };
}
