# Optional ingress (edge routing)

A Nix-Swarm cluster needs **no proxy and no edge**. Operator access, the
control path, and application traffic all work over the trusted private
network or an SSH tunnel. An edge — Caddy in these examples, though nginx,
Traefik, or an existing NixOS ACME setup fit the same pattern — is an
**optional integration point** you add only when you want name-based or
TLS-terminated access to an app.

Nix-Swarm never configures the proxy. Caddy is an ordinary user-owned NixOS
service whose placement (`caddy.service`, one replica, an `allowedNodes`
list) is managed like any other unit; the `services.caddy` module content is
yours, applied as a NixOS generation, and never rewritten by Nix-Swarm or
touched through the Admin API.

## Why an edge is optional

- **The control path has no HTTP dependency.** The CLI, TUI, query socket,
  and Erlang distribution (EPMD/distribution ports) connect directly to
  nodes. Nothing in Nix-Swarm reverse-proxies or URL-routes control traffic.
- **Direct access works.** On a trusted LAN, reach an app at
  `http://node:port`. For remote operator access, an SSH tunnel
  (`ssh -L 8080:127.0.0.1:8080 node`) replaces any proxy; the port stays
  bound to the private interface only.
- **The edge adds name-based routing and TLS**, not reachability.

## The standard pattern

Put a **static list of health-checked upstreams** in front of the app. Each
deployed unit has a stable systemd slot and a stable port; Caddy actively
checks every candidate and only forwards to healthy ones.

```caddy
app.example.internal {
  reverse_proxy 10.100.0.1:8080 10.100.0.1:8081 10.100.0.2:8080 10.100.0.2:8081 {
    lb_policy round_robin
    health_uri /healthz
    health_interval 5s
    health_timeout 2s
    fail_duration 10s
  }
}
```

Health-check semantics are what make the static list safe:

- A node that dies fails its health check and is dropped from rotation within
  a few intervals; when it returns, it is re-added automatically.
- When a replica relocates (failover, node maintenance), it moves to another
  node that is **already in the static list** — placement only ever moves a
  unit inside its eligible node set, so the healthy upstream for that slot
  already exists and no Caddy change is needed at relocation time.
- `health_uri` must be an endpoint the app actually serves with 2xx/3xx. The
  examples' demo service answers `200 OK` at `/`; a real app should expose
  `/healthz` (or equivalent) and the example above should be changed to it.

### Why static upstreams never go stale

Placement is bounded. A service that sets `allowedNodes` can only run on
those nodes (`lib/nix_swarm/placement.ex`, `eligible_node?/3`); a service
that omits `allowedNodes` may run on **any configured active node**. So the
closed form of the rule is:

- with `allowedNodes` set — list every node in it, for every slot port the
  unit template can produce, and the list stays exact;
- without `allowedNodes` — either set one (recommended for an edge-routed
  service) or list the slot ports of every node you may add to the cluster.

The example below lists both slot ports (8080, 8081) of both nodes. When a
slot is not placed on a given node that endpoint is simply unhealthy and
unused; when the unit relocates its endpoint is already present and healthy.

### Upstream addressing follows the deployment posture

- **Trusted LAN (default):** use the node's LAN address — a real IP, or a
  hostname that resolves only on that network. `example-node-a.local` in the
  example files is a stand-in for the operator's own name/address scheme.
- **Overlay mesh (optional):** when nodes sit on different networks/NAT and
  use the NetBird overlay (`netbird0`), list the overlay IPs instead.
- Never bind application or edge ports on `0.0.0.0` on a public interface:
  open app ports and `80`/`443` only on the named private interface
  (`networking.firewall.interfaces.<name>.allowedTCPPorts`), matching the
  cluster's trusted-LAN default posture.

## NixOS module form

The same pattern as a NixOS module, as shipped in the examples:

```nix
{ ... }:
{
  services.caddy = {
    enable = true;

    virtualHosts."http://app.example.internal".extraConfig = ''
      reverse_proxy 10.100.0.1:8080 10.100.0.1:8081 10.100.0.2:8080 10.100.0.2:8081 {
        lb_policy round_robin
        health_uri /healthz
        health_interval 5s
        health_timeout 2s
        fail_duration 10s
      }
    '';
  };
}
```

Apply Caddy changes through the reviewed workflow like any other generation:

```bash
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
```

## Load-balancing policy

- `lb_policy round_robin` — the default here and in the examples; even
  distribution across healthy upstreams.
- `lb_policy least_conn` — prefer when request cost varies and you want the
  least-loaded healthy upstream first.
- Sticky sessions are not configured by default. Stateful services run
  `replicas: 1` (single writer), so one healthy upstream is active and no
  stickiness is needed; if a stateless app needs sticky routing, Caddy's
  `lb_policy` cookie/sticky options are available but keep in mind a failed
  node's sessions cannot be served by its replacement.

## Availability: the single-edge caveat

A single edge node is a single point of failure for *edge-routed* access
(direct/SSH access to apps is unaffected). For a homelab this is an accepted
trade-off. To reduce it, run two edge nodes with the same upstream lists and
point DNS at both (round-robin A/AAAA records); the application layer stays
single-writer and unchanged. Health checks do not span edges, so DNS-level
rotation is the mitigation — there is no cross-edge failover coordination.

## TLS

- For a public site, use a real domain and let Caddy's automatic HTTPS issue
  and renew certificates; expose `80`/`443` on the edge node's private
  interface and let the edge reach upstreams on the private network.
- For internal `.internal`/`.local` names, plain `http://` (as in the
  examples) is the documented default; nothing in Nix-Swarm depends on TLS.

## Deferred: dynamic upstream rendering

Rendering Caddy's upstream list from live placement is a deliberate future
option, not part of this release. The static health-checked pattern above is
the supported way to route; it stays correct because of `allowedNodes`
bounds and relocation-inside-the-list, and it keeps the edge configuration
pure user-owned Nix with no dependency on cluster state at render time.

## References

- Working examples: `examples/config/services/caddy-edge.nix` (two-node,
  slot superset) and `examples/starter/services/caddy-edge.nix` (single node).
- Starter README and `docs/GETTING_STARTED.md` §6 walk through applying edits.
- Caddy documentation: `https://caddyserver.com/docs/caddyfile/directives/reverse_proxy`.
