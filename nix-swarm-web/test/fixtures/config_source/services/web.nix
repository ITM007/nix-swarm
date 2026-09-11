{ config, pkgs, lib, ... }:
{
  services.example-web.port = 8080;
  systemd.services.example-web = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.hello}/bin/hello";
      Restart = "always";
    };
  };
}
