# Minimal product scope

Nix-Swarm is not intended to reproduce Docker Swarm. It is a small orchestration
layer for systemd services on NixOS homelabs and small-business networks.

## Ownership boundaries

- Nix code owns desired state, deployment inputs, placement policy, and history.
- systemd owns processes, dependencies, readiness, watchdogs, restarts,
  credentials, cgroups, notifications, and journald logs.
- the BEAM owns supervision, trusted peer RPC, membership, deterministic
  placement, and reconciliation.
- Nix-Swarm stores operational observations, never a second desired-state model.
- the TUI is a read-only projection for operators.

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
   operations, or launch the read-only TUI.
5. Use `service restart --name NAME --yes` for one bounded maintenance action;
   start/stop remain declarative through `replicas`.
6. Use deterministic placement across active nodes, with `allowedNodes` as the
   only per-service placement restriction.
7. Use the small CPU-and-memory autoscaling policy against existing declared
   capacity. Autoscaling does not provision machines or manage databases.

## Deliberate exclusions and migration boundary

Nix-Swarm is a simple systemd orchestrator for homelabs and small businesses.
Downtime is acceptable. Databases, volumes, storage, stateful replication,
live migration, routing meshes, virtual IPs, machine provisioning, or a custom
monitoring or secret stack are not managed by Nix-Swarm. Put those concerns in
ordinary NixOS modules and systemd configuration.

The following are not public options: ingress metadata, healthcheck metadata, arbitrary
settings, preferred nodes, node labels, service constraints,
`maxReplicasPerNode`, readiness or runtime timing, autoscaling expert knobs,
and canary/parallel rollout controls. Rollout policy is fixed and safe
internally; operators do not select batch width, canaries, or readiness timing.

The TUI never mutates state. Nix and Git remain authoritative, while runtime
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
guarantees during a network partition. A partition can temporarily run duplicate
stateless replicas. Stateful services and databases must provide their own
replication, locking, storage, and split-brain protection outside Nix-Swarm.
