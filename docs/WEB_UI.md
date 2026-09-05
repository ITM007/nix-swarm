# Nix-Swarm Web UI

`nix-swarm-web` is a separate, optional Phoenix/LiveView read-only release. It
projects the existing Nix-Swarm query API; it is not a second control plane and
it is not a replacement for the CLI recovery path.

## Security boundary

- The web service binds only to IPv4 loopback (`127.0.0.1`). There is no bind
  address or firewall escape hatch in the module.
- Access from another machine uses an operator-owned SSH tunnel or a
  user-managed reverse proxy on the same host.
- The service does not join distributed Erlang and never receives the BEAM
  cookie, SSH keys, Git credentials, or a source-tree path.
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

## Tunnel access

On the operator workstation, forward a local port to the node's loopback
listener:

```bash
ssh -N -L 4000:127.0.0.1:4000 root@node-a
```

Then open `http://127.0.0.1:4000/`. Use `cluster doctor` and
`cluster status` if the web service or tunnel is unavailable; CLI recovery and
stateful `cluster heal` remain supported independently.

## Views

Release 1 provides Dashboard, Network, Nodes, Services, Drift, and Logs views,
plus in-memory downloads for the current bounded data. All views consume one
supervised query broker. A slow or failed query is shown as stale/degraded and
the last good snapshot is retained rather than replaced with an empty healthy
state.

The agent strips terminal control sequences from log text. The browser renders
log text as escaped text, never as raw HTML. Log requests are bounded to 1–1000
lines; the default web log request is 200 lines. Search is a literal substring
search over the currently fetched bounded result, not a regex or history scan.

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
