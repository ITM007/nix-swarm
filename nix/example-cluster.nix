{
  services.swarm = {
    enable = true;
    package = ./result;
    nodeName = "node-a@10.0.0.11";
    cookieFile = "/etc/nixos/nix-swarm/secrets/swarm.cookie";

    peers = [
      "node-a@10.0.0.11"
      "node-b@10.0.0.12"
      "node-c@10.0.0.13"
    ];

    nodes = {
      "node-a@10.0.0.11".labels = [ "ssd" "edge" ];
      "node-b@10.0.0.12".labels = [ "ssd" ];
      "node-c@10.0.0.13".labels = [ "ssd" "edge" ];
    };

    services.gitea = {
      replicas = 2;
      unitTemplate = "gitea@%{slot}.service";
      constraints = [ "ssd" ];
      preferredNodes = [ "node-a@10.0.0.11" "node-b@10.0.0.12" ];
      healthcheck = "/run/current-system/sw/bin/curl -fsS http://127.0.0.1:3000/";
      settings = {
        domain = "gitea.home";
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
        host = "gitea.home";
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
