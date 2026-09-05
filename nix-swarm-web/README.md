# nix-swarm-web

`nix-swarm-web` is the separate, read-only Phoenix/LiveView status surface for
Nix-Swarm. It is intentionally unauthenticated and must be bound to IPv4
loopback only. It never joins distributed Erlang and never receives the
Nix-Swarm BEAM cookie.

## Development

All commands use the repository development shell from the repository root:

```bash
nix develop --command bash -lc 'cd nix-swarm-web && mix deps.get'
nix develop --command bash -lc 'cd nix-swarm-web && mix format'
nix develop --command bash -lc 'cd nix-swarm-web && mix test --warnings-as-errors --seed 0'
nix develop --command bash -lc 'cd nix-swarm-web && mix compile --warnings-as-errors'
nix develop --command bash -lc 'cd nix-swarm-web && mix hex.audit'
```

The test suite uses fixture snapshots and injectable query functions; it does
not require a running Nix-Swarm agent or query socket. Production polling uses
the local Unix query socket configured by `NIX_SWARM_QUERY_SOCKET` (default:
`/run/nix-swarm/query.sock`).

## Running locally

Development and test configuration can use the normal Phoenix server. A
production release requires a runtime-generated secret file:

```bash
SECRET_KEY_BASE_FILE=/run/nix-swarm-web/secret \
NIX_SWARM_QUERY_SOCKET=/run/nix-swarm/query.sock \
PORT=4000 \
nix develop --command bash -lc 'cd nix-swarm-web && MIX_ENV=prod mix phx.server'
```

The production endpoint hard-codes `127.0.0.1`; there is no supported
non-loopback bind or firewall-opening option. To browse it from another
machine, use an SSH tunnel:

```bash
ssh -N -L 4000:127.0.0.1:4000 operator@node.example
```

Then open `http://127.0.0.1:4000/` locally.

## Read-only surface

The release provides:

- dashboard and network/ownership map;
- configured nodes and node details;
- services, slots, ownership, and service details;
- drift and consistency findings;
- bounded cluster, node, and service logs with literal search/filtering;
- JSON, CSV, and bounded text exports.

Every view shows stale, degraded, or unknown data explicitly instead of
claiming a healthy result when the query is partial. The browser has no deploy,
edit, restart, heal, source-tree, Git, SSH-key, or write route. Recovery and
mutation remain CLI operations.

## Security boundary

The web process only needs read access to the query socket, normally through
the `nix-swarm-operators` group. It must not be given the BEAM distribution
cookie, deployment credentials, Git credentials, or write access to the
Nix-Swarm source tree. Keep the endpoint behind loopback and an operator-owned
SSH tunnel or local reverse proxy.

For the deployment and parity acceptance criteria, see:

- [`docs/WEB_UI.md`](../docs/WEB_UI.md)
- [`docs/WEB_TUI_PARITY.md`](../docs/WEB_TUI_PARITY.md)
