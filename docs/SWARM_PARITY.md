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

## Supported feature set

In impact-to-effort order:

1. Declarative nodes, services, replicas, unit templates, and labels in Nix.
2. Read-only plan, status, doctor, logs, metrics, and TUI overview.
3. Idempotent local reconciliation against systemd unit state.
4. Deterministic placement with allowed and preferred nodes.
5. Durable local records of the last generation, assignment, health, and result.
6. Native NixOS flake evaluation, health-gated deployment, upgrades, and rollback.
7. Declarative `active` and `draining` node availability.
8. systemd-native readiness, watchdog, restart policy, credentials, journald,
   cgroup accounting, and `OnFailure=` notifications.
9. Restricted SSH-to-Unix-socket operator queries without a BEAM cookie.
10. Private-network deployment using normal firewall and VPN facilities.
11. Optional bounded CPU autoscaling for stateless services; scaling decisions
    are temporary observations and never override Nix-declared capacity.

## Deliberate exclusions

- no mutable TUI controls
- no ad-hoc service start/stop state
- no Mnesia, custom SQL database, or distributed secret store
- no overlay network, routing mesh, container runtime, or volume orchestration
- no dynamic bin-packer, preemption, or multi-tenant scheduler
- no custom logging, monitoring, notification, or PKI stack
- no consensus dependency unless real users require automatic controller HA

If automatic manager failover becomes necessary, a small three-node Raft log is
the next appropriate addition. It should remain optional and must not replace
Nix as the source of desired configuration.

## Partition and stateful-workload boundary

Nix-Swarm is leaderless and does not provide quorum, fencing, or single-writer
guarantees during a network partition. A partition can temporarily run duplicate
stateless replicas. Stateful services and databases must provide their own
replication, locking, storage, and split-brain protection outside Nix-Swarm.
