{ ... }:
{
  # Caddy is ordinary user-owned NixOS configuration. Nix-Swarm only keeps
  # caddy.service on the edge node (see cluster.nix) and deploys this
  # generation through apply; it never rewrites this module or calls the
  # Caddy Admin API. Pattern reference: docs/INGRESS.md.
  services.caddy = {
    enable = true;

    # The upstream list is static and health-checked: every slot port of
    # every allowed node is listed up front, and Caddy's active checks only
    # forward to endpoints that answer. A relocated replica moves inside this
    # list (placement is bounded by allowedNodes), so failover needs no Caddy
    # change — the unhealthy endpoint drops out and the healthy one serves.
    virtualHosts."http://app.example.internal".extraConfig = ''
      reverse_proxy example-node-a.local:8080 example-node-a.local:8081 example-node-b.local:8080 example-node-b.local:8081 {
        lb_policy round_robin
        health_uri /
        health_interval 5s
        health_timeout 2s
        fail_duration 10s
      }
    '';
  };

  # Expose the edge only on the private network. On a trusted LAN name the
  # actual interface (for example "enp2s0"); in the overlay variant use
  # netbird0. Adjust both this interface and the node names above for the
  # operator's private network.
  networking.firewall.interfaces.netbird0.allowedTCPPorts = [ 80 443 ];
}
