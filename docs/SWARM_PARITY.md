# Minimal product scope

Nix-Swarm is not intended to reproduce Docker Swarm. It is a small orchestration
layer for systemd services on NixOS homelabs and small-business networks:
stateless replicas plus single-writer stateful apps with scheduled backup and
verified restore-on-placement.

## Ownership boundaries

- Nix code owns desired state, deployment inputs, placement policy, and history.
- systemd owns processes, dependencies, readiness, watchdogs, restarts,
  credentials, cgroups, notifications, and journald logs.
- the BEAM owns supervision, trusted peer RPC, membership, deterministic
  placement, and reconciliation.
- Nix-Swarm stores operational observations, never a second desired-state model.
- the web UI is a read-only projection for operators.

Optional edge routing is user-owned NixOS configuration. A standard Caddy
service may be placed on one declared edge node and use health-checked static
candidate backends, but Nix-Swarm does not provide a routing mesh, virtual IP,
dynamic proxy API, or automatic certificate-state replication.

## Supported feature set

The supported public workflow is intentionally narrower than Docker Swarm:

1. Declare machines and services in `.nix` and keep that tree in Git.
2. Use `cluster plan` for a read-only preview and `cluster apply --yes` as the
   normal mutation path.
3. Use `cluster rollback --yes`, `cluster upgrade --yes`, and
   `cluster credentials rotate --yes` for explicit maintenance.
4. Use `cluster doctor`, `cluster status`, and `service logs` for read-only
   operations.
5. Use `service restart --name NAME --yes` for one bounded maintenance action;
   start/stop remain declarative through `replicas`.
6. Use deterministic placement across active nodes, with `allowedNodes` as the
   only per-service placement restriction.
7. Use the small CPU-and-memory autoscaling policy against existing declared
   capacity. Autoscaling does not provision machines or manage databases.
8. Declare single-writer application state (`state.dirs` + backup schedule) and
   recover it onto a surviving eligible node with `cluster heal --yes` after
   the owning node fails. State is node-local: no network mounts, no live file
   sync, no multi-writer replication.

## Stateful apps (Swarm volumes → `state.dirs`)

| Docker Swarm | Nix-Swarm |
|---|---|
| named volume | declared `state.dirs` on the owning node |
| volume backup (external) | borgmatic schedule to an operator-chosen repo (Tier 1) |
| replicate service | stateless `replicas: N` service |
| global service | `replicas: 1` stateful service + `cluster heal` |

A stateful service is single-writer (`replicas: 1`, enforced). The reconciler
never starts its unit on a node whose state directories are absent — the unit
reports `:awaiting_heal` in `cluster status` until an operator runs
`cluster heal`. Restore goes to a staging directory, is verified, then moved
into place before the unit starts; a failed or empty restore never touches the
target. Full contract: docs/STATEFUL_SERVICES.md.

## Deliberate exclusions and migration boundary

Nix-Swarm is a simple systemd orchestrator for homelabs and small businesses.
Downtime is acceptable. Machine provisioning, live migration, network-mounted
storage, live file sync, routing meshes, virtual IPs, or a custom monitoring
or secret stack are not managed by Nix-Swarm. Declared application state
directories with scheduled backup and verified restore are in scope; raw
database engines and their replication are not — put a multi-writer database
in ordinary NixOS modules and systemd configuration.

The following are not public options: ingress metadata, healthcheck metadata, arbitrary
settings, preferred nodes, node labels, service constraints,
`maxReplicasPerNode`, readiness or runtime timing, autoscaling expert knobs,
and canary/parallel rollout controls. Rollout policy is fixed and safe
internally; operators do not select batch width, canaries, or readiness timing.

The web UI never mutates state. Nix and Git remain authoritative, while runtime
observations are diagnostics only. Removed commands must return a concise
migration error and must not execute compatibility code: use `cluster apply`
instead of `cluster init`/`ensure`/`rebuild`, `cluster status` instead of
`cluster members`, `cluster credentials rotate` instead of `cluster credentials`, and copy/edit
the starter instead of service scaffolding commands.

If automatic manager failover becomes necessary, a small three-node Raft log is
the next appropriate addition. It should remain optional and must not replace
Nix as the source of desired configuration.

## Partition and stateful-workload boundary

Nix-Swarm is leaderless and does not provide quorum, fencing, or single-writer
guarantees for stateless replicas during a network partition. A partition can
temporarily run duplicate stateless replicas.

Stateful services are the exception by construction: they are single-writer
(`replicas: 1` enforced by validation), so a partition can never produce two
live writers of one state directory. The reconciler refuses to start a
stateful unit whose declared state is absent (`:awaiting_heal`), and
`cluster heal` restores the latest snapshot onto a surviving eligible node
before starting it there. When the original owner returns, deterministic
placement keeps exactly one owner: the unit on the non-owner node is stopped
and the owner only starts if its own state is present and fresh enough to
trust (otherwise it reports `:awaiting_heal` again). State is never
live-synced or network-mounted; recovery is always restore-then-start.
