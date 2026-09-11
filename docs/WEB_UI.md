# Nix-Swarm Web UI

`nix-swarm-web` is a separate, optional Phoenix/LiveView read-only release. It
projects the existing Nix-Swarm query API; it is not a second control plane and
it is not a replacement for the CLI recovery path.

## Security boundary

- The web service binds only to IPv4 loopback (`127.0.0.1`). There is no bind
  address or firewall escape hatch in the module.
- HTTP requests are accepted only for the explicit loopback and development
  tunnel authorities (`127.0.0.1` and `nix-swarm-dev.localhost`); unknown Host
  values are rejected before routes or exports run.
- LiveView websocket origins must match the request's scheme, host, and port;
  loopback binding is not used as a substitute for Host/Origin validation.
- Access from another machine uses an operator-owned SSH tunnel or a
  user-managed reverse proxy on the same host.
- The service does not join distributed Erlang and never receives the BEAM
  cookie, SSH keys, Git credentials, or a source-tree path. The only exception
  is the explicit opt-in `NIX_SWARM_CONFIG_SOURCE` environment variable (the
  `:nix_swarm_web, :config_source` setting), which exposes a **Nix
  configuration** section in the map sidebar. When set, that section lists the
  operator's applied Nix files read-only and lets the operator open one in the
  syntax-highlighted viewer. Only `*.nix` files under that directory are
  served: `secrets/` and hidden entries are never scanned, credential-looking
  filenames are excluded, reads are limited to the scanned index, and each
  file is capped at 512 KiB. Nothing is evaluated, deployed, or mutated. When
  unset, the section remains visible with the command needed to connect a
  source, but no files are listed.
- The query broker reads only `/run/nix-swarm/query.sock` (or the explicitly
  configured absolute local socket path) using the existing bounded JSON
  profile.
- There are no accounts, login routes, OAuth/OIDC, roles, write controls, or
  per-user sessions-as-identity.
- Read-only mode has no persistent application database or server-side export
  files. Browser downloads are generated from the current in-memory snapshot.

The unauthenticated design is safe only while the listener remains loopback.
Do not publish the port through a firewall or bind it to a LAN address.

## Install and enable

The package and module are exported separately from the core package:

```nix
{
  inputs.nix-swarm.url = "github:example/nix-swarm";

  outputs = { self, nix-swarm, ... }: {
    nixosConfigurations.node = nixpkgs.lib.nixosSystem {
      modules = [
        nix-swarm.nixosModules.nix-swarm
        nix-swarm.nixosModules.nix-swarm-web
        ({ ... }: {
          services.nix-swarm-web.enable = true;
          # Optional: show safe .nix files from this source in the map sidebar.
          # services.nix-swarm-web.configSource = "/etc/nix-swarm/source";
          # Optional: restrict the one replica to named configured peers.
          # services.nix-swarm-web.allowedNodes = [ "nix-swarm@node" ];
        })
      ];
    };
  };
}
```

The module registers `nix-swarm-web.service` as one stateless Nix-Swarm
replica. It has no `wantedBy` target; the reconciler chooses one eligible node.
The systemd unit is hardened with a private runtime directory, no new
privileges, a read-only protected system, no capabilities, and only Unix/IPv4
address families. The module does not open a firewall port.

The service generates its Phoenix secret in the private runtime directory at
startup. The secret is passed by file path only and is not rendered into Nix,
argv, the environment, or the journal.

For the repository's local development harness, connect the operator source
explicitly before starting it:

```bash
NIX_SWARM_CONFIG_SOURCE="$HOME/.config/nix-swarm" scripts/dev.nu up
```

The map sidebar will then show the **Nix configuration** section. Click any
listed file to open the read-only viewer; the source is never evaluated by the
web process.

## Tunnel access

On the operator workstation, forward a local port to the node's loopback
listener:

```bash
ssh -N -L 4000:127.0.0.1:4000 root@node-a
```

Then open `http://127.0.0.1:4000/`. Use `cluster doctor` and
`cluster status` if the web service or tunnel is unavailable; CLI recovery and
stateful `cluster heal` remain supported independently.

## Single-page map surface

Release 1 provides one interactive dashboard centered on a drawio-style SVG
cluster map. Node cards connect to service-slot cards through ownership edges.
The browser can pan the canvas, zoom with the wheel or toolbar, drag cards to
arrange the diagram, fit/reset the layout, and select an item to populate the
inspector. A collapsible accessible table exposes the same service ownership
data without requiring SVG interaction. Former `/network`, `/nodes`,
`/services`, `/drift`, and `/logs` URLs are compatibility entry points to the
same map surface rather than separate interactive pages.

The surface consumes one supervised query broker. A slow or failed query is
shown as stale/degraded and the last good snapshot is retained rather than
replaced with an empty healthy state. In-memory JSON, CSV, and bounded text
exports remain available as HTTP downloads. Log queries run outside the broker's
snapshot mailbox with bounded admission, caller cancellation, and a capped
expiring cache, so abandoned log downloads do not retain obsolete work.

The agent strips terminal control sequences from log text. The browser renders
log text as escaped text, never as raw HTML. Log requests are bounded to 1–1000
lines; the default web log request is 200 lines. Search is a literal substring
search over the currently fetched bounded result, not a regex or history scan.

## Network traffic visibility

The current snapshot already has a useful Layer 4 baseline:

- each machine reports cumulative receive/transmit byte counters from its
  non-loopback interfaces;
- systemd service metrics can report cumulative IP ingress/egress bytes for a
  unit; and
- the web broker derives byte rates from advancing snapshots without treating a
  counter reset or stale sample as valid.

Layer 4 is the right default for Nix-Swarm because it works across arbitrary
systemd workloads with low overhead. It answers how many bytes are moving and
which host, interface, port, or unit is involved. It does not identify HTTP
routes, status codes, request latency, or gRPC methods. Those are Layer 7
signals and require instrumentation at the application or an HTTP-aware edge
such as Caddy. Keep that instrumentation optional; do not put protocol parsing
or a mandatory proxy in the core agent.

The map includes a small Hubble-style traffic panel. It shows receive/transmit
rates for machines and service units after two advancing samples, plus a
logical Nix-Swarm proxy card. Dashed proxy arrows represent declared static
routes resolved to cluster machines; they are not packet captures and are kept
visually separate from observed counter rates. The proxy card also shows its
configured listener, instance count, route count, and any observed proxy-unit
traffic.

## Add New Machine helper

The map sidebar keeps an **Add New Machine** button. Clicking it opens a
read-only modal containing the preparation instructions and form. It accepts a
target hostname, SSH deployment host, NixOS configuration attribute, private
firewall interface, and existing distributed-Erlang peer names. It generates a
copyable machine module and a central `services.nix-swarm.nodes` inventory
snippet.

The generated module contains no cookie or deployment credential. The operator
must still add the inventory entry and complete peer list to the deployment
flake, review `nix-swarm cluster plan`, and run the explicit
`nix-swarm cluster apply --yes` workflow. Normal apply enrolls a missing cookie
over verified SSH. Rebuilding the copied machine file alone does not create a
mutable registration record or bypass the Nix desired-state model.

## Failure and freshness semantics

- **Unknown** means the required field was not returned; it is not healthy.
- **Down/unreachable** means the agent could not answer for that node.
- **Degraded** includes unplaced slots, failed units, awaiting-heal state, and
  placement/configuration diagnostics.
- **Stale** means the broker retained the last good normalized snapshot after a
  failed refresh. The page shows the last successful capture time and the
  current query error.
- **Fresh** means the latest bounded overview query normalized successfully;
  it does not mean every workload is healthy.

## Scope limits

This release has no deploy, apply, rollback, upgrade, credential rotation,
restart, heal, source editing, Git diff, or arbitrary command/file operation.
Those actions remain CLI/Nix workflows. Write mode, if added later, is a
separate opt-in release and must not be inferred from this UI.
