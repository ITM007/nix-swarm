{ ... }:
{
  # Caddy is ordinary user-owned NixOS configuration. Nix-Swarm only keeps
  # caddy.service on the edge node and deploys this generation through apply.
  services.caddy = {
    enable = true;

    virtualHosts."http://app.example.internal".extraConfig = ''
      # Every declared example-web slot has a stable port. Caddy's active
      # checks select the endpoint whose systemd slot is currently healthy.
      reverse_proxy example-node-a.local:8080 example-node-a.local:8081 example-node-b.local:8080 example-node-b.local:8081 {
        health_uri /
        health_interval 5s
        health_timeout 2s
        fail_duration 10s
      }
    '';
  };

  # The example exposes Caddy only on the trusted private interface. Adjust
  # this interface and the node names for the operator's private network.
  networking.firewall.interfaces.wg0.allowedTCPPorts = [ 80 443 ];
}
