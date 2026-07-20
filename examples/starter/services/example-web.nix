{ lib, pkgs, ... }:
{
  systemd.services.example-web = {
    description = "Nix-Swarm example workload";
    wantedBy = lib.mkForce [ ];

    serviceConfig = {
      DynamicUser = true;
      ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080 --bind 127.0.0.1";
      Restart = "on-failure";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };
}
