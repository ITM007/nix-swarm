{ pkgs, ... }:
{
  systemd.services.example-web = {
    description = "Example Nix-Swarm workload";
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${pkgs.bash}/bin/bash -lc 'while true; do printf \"HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\n\\r\\nok\" | ${pkgs.netcat}/bin/nc -l -p 8080 -q 1; done'";
      Restart = "always";
      RestartSec = 2;
    };
  };
}
