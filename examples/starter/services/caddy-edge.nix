{ ... }:
{
  services.caddy = {
    enable = true;

    # User-owned Caddy policy. Edit this module and apply the resulting NixOS
    # generation; Nix-Swarm never rewrites this configuration. This starter is
    # a single node, so the health-checked upstream is local; the multi-node
    # form (static slot superset with lb_policy round_robin) is documented in
    # docs/INGRESS.md and shown in examples/config/services/caddy-edge.nix.
    virtualHosts."http://app.example.internal".extraConfig = ''
      reverse_proxy 127.0.0.1:8080 {
        health_uri /
        health_interval 5s
        health_timeout 2s
        fail_duration 10s
      }
    '';
  };

  # Keep the Nix-Swarm placement contract beside the edge service it owns.
  services.nix-swarm.services.caddy = {
    replicas = 1;
    unitTemplate = "caddy.service";
    allowedNodes = [ "nix-swarm@node-a" ];
  };
}
