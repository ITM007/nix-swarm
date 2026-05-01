{ lib, pkgs, ... }:
{
  systemd.services."example-web@" = {
    description = "Example Nix-Swarm workload";
    wantedBy = lib.mkForce [];

    serviceConfig = {
      ExecStart = "${pkgs.bash}/bin/bash -lc 'port=$((8080 + %i)); while true; do printf \"HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\n\\r\\nok\" | ${pkgs.netcat}/bin/nc -l -p \"$port\" -q 1; done'";
      Restart = "always";
      RestartSec = 2;
    };
  };
}
