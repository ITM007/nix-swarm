{
  services.nix-swarm = {
    enable = true;
    package = ./result;
    nodeName = "nix-swarm@10.0.0.11";
    cookieFile = "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie";

    peers = [
      "nix-swarm@10.0.0.11"
      "nix-swarm@10.0.0.12"
      "nix-swarm@10.0.0.13"
    ];

    nodes = {
      "nix-swarm@10.0.0.11".labels = [ "ssd" "edge" ];
      "nix-swarm@10.0.0.12".labels = [ "ssd" ];
      "nix-swarm@10.0.0.13".labels = [ "ssd" "edge" ];
    };

    services.gitea = {
      replicas = 2;
      unitTemplate = "gitea@%{slot}.service";
      constraints = [ "ssd" ];
      preferredNodes = [ "nix-swarm@10.0.0.11" "nix-swarm@10.0.0.12" ];
      healthcheck = "/run/current-system/sw/bin/curl -fsS http://127.0.0.1:3000/";
      settings = {
        domain = "gitea.example.internal";
        httpPort = 3000;
        sshPort = 2222;
      };
    };

    services.proxy = {
      replicas = 1;
      unitTemplate = "proxy@%{slot}.service";
      constraints = [ "edge" ];
      healthcheck = "/run/current-system/sw/bin/curl -fsS http://127.0.0.1:8080/health";
      settings = {
        host = "gitea.example.internal";
        backendPort = 3000;
      };
    };

    runtime = {
      connectIntervalMs = 500;
      reconcileIntervalMs = 500;
      generation = "example";
    };
  };
}
