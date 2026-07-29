{ ... }:
{
  services.caddy = {
    enable = true;

    # User-owned Caddy policy. Edit this module and apply the resulting NixOS
    # generation; Nix-Swarm never rewrites this configuration.
    virtualHosts."http://app.example.internal".extraConfig = ''
      reverse_proxy 127.0.0.1:8080 {
        health_uri /
        health_interval 5s
        health_timeout 2s
        fail_duration 10s
      }
    '';
  };
}
