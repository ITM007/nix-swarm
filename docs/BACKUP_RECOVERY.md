# Backup and recovery

What Nix-Swarm persists, what you must back up, and how to bring a node
back after loss or corruption. Recovery mutations are explicit Nix
deployments or `cluster rollback`; there is no hidden mutable state to
repair by hand.

## Ownership boundary

Nix-Swarm is code-first and leaderless. Its design goal is that node-local
state is **recoverable by redeployment**, not precious:

- The NixOS configuration **source tree is the desired state**. It must
  survive in Git (a remote you control, e.g. Forgejo). Everything else can
  be regenerated from it.
- Nodes store only **node-local operational observations** (DETS files such
  as `operational-state.dets`) under `/var/lib/nix-swarm/**`. These are
  caches of what the agent has observed; they are never authoritative
  desired state, are safe to delete, and must **never be copied between
  nodes**.
- Application data inside managed service units is owned by the
  application and its operator. Stateful application backup is not part of
  the v1.0 product; treat each workload's data directory as your
  responsibility today (see [App data](#app-data-ownership)).

## Backup inventory

| Item | Where it lives | Authority | Policy |
|---|---|---|---|
| Source tree + `flake.lock` | your Git remote | desired state | push every change; the lock must match what was applied |
| Cluster credential (cookie) | `/etc/nixos/nix-swarm/secrets/nix-swarm.cookie` on each node (root-owned, mode 0400/0600) | shared secret | back up with your secret store (sops-nix/agenix/password manager); **never** commit it |
| Node-local observations | `/var/lib/nix-swarm/**` on each node | ephemeral | no backup needed; rebuilt by the agent |
| Managed app data | per-application paths on the node | application | operator-owned (below) |

### Cluster credential

The cookie is the cluster's only shared secret and the sole thing that
cannot be regenerated from the source tree. Protect it like a root
password:

- Store one copy outside the cluster (encrypted secret store). Note the
  cluster it belongs to and the node names, because the cookie constrains
  the `nodeName` prefix.
- **Never** put it in Git, in a Nix store path, or on an operator laptop in
  cleartext.
- If a node's cookie is lost or mismatched, restore the backed-up file with
  mode 0600 and restart `nix-swarmd`, or rotate the cluster credential
  (see [Install or rotate the cluster credential](OPERATIONS.md)) — rotation
  stops all agents, replaces the cookie everywhere, restarts, and rolls back
  on failure. Mixed cookies partition the cluster; after a botched rotation
  the agents simply cannot see each other until every node shares one cookie.
- The cookie is delivered to the agent as a systemd `LoadCredential` and is
  never visible in process arguments or the rendered environment.

### App data ownership

Nix-Swarm v1.0 manages **stateless** units: it supervises lifecycle,
placement, and reconciliation, but does not snapshot workload data.
Back up each stateful application yourself (borg/restic + off-site target,
or the application's own export tooling) on whatever cadence its RPO
demands. The post-v1.0 stateful-units design (declared restore from backup)
does not change this today: anything you do not back up is lost when the
node is lost.

## Recovery procedures

### A node will not rejoin after a restart or reboot

The agent self-heals: node startup retries peer connections with backoff
(1s rising to 30s) and membership uses `net_ticktime 10`, so a node that
comes up after the overlay is ready rejoins within seconds and the
reconciler converges its units back to the declared replicas. If it does
not rejoin:

1. `systemctl status nix-swarmd` on the node — is the agent up?
2. `journalctl -u nix-swarmd -n 100` — look for credential, config, or
   peer-connect errors.
3. Verify cookie, node name, and the private-interface ports `4369/4370`
   (see the Troubleshooting table in [Operations](OPERATIONS.md)).
4. `nix-swarm cluster status` from the operator machine.

### Temporary duplicates during a partition

Nix-Swarm has no consensus layer. When the cluster partitions, the same
stateless service may legitimately be started on both sides (each side
believes it must meet the replica count). This is **accepted behavior**:
when the partition heals, the reconciler converges to the declared
placement and the duplicates stop. Do not hand-kill units during a
partition; fix the network, let membership settle, and verify with
`cluster status` that every service is at its declared replicas.

### Full node loss (disk failure / reinstall)

Restore order:

1. Install NixOS on the replacement hardware.
2. Apply the cluster configuration from the source tree
   (`nixos-rebuild switch --flake .#<host>`), which recreates the
   `nix-swarm` module, the `nix-swarm` user, the unit, and state
   directories.
3. Install the cluster credential at
   `/etc/nixos/nix-swarm/secrets/nix-swarm.cookie` (root-owned, 0600) —
   from your secret-store backup, or via `nix-swarm cluster credentials rotate`
   once the node is reachable, or by copying it from a live peer.
4. Start (or let the deployment start) `nix-swarmd`. The agent registers,
   rejoins, and the reconciler places units per the declared topology.
5. Verify: `nix-swarm cluster status` shows the node active and each
   service at its replica count; spot-check `nix-swarm service logs <name>`.

Nothing else on the node needs restoring: `/var/lib/nix-swarm` rebuilds
itself from observation, and the old DETS file (if you carried it over)
is harmless but should not be treated as state to preserve — the agent
also quarantines a corrupt `operational-state.dets` automatically on
startup and continues empty.

### Rolling back a bad change

Two layers, in order of preference:

1. **Declarative rollback of the previous generation:**
   `nix-swarm cluster rollback --source . --yes` activates each target's
   previous NixOS generation through the same health gate. Failed applies
   already auto-rollback attempted hosts and report the outcome.
2. **Boot-level fallback:** on a node, `nixos-rebuild --rollback` or
   booting a previous generation from the boot loader. This is per-node
   and bypasses the rollout gate — use it only when the agent itself is
   the thing you must undo.

After either, converge again with `cluster plan` / `cluster apply` once the
source tree says what you actually want.

### Cookie rotation as a recovery tool

If the credential is compromised or irrecoverable on any node, rotation is
the recovery path. It requires stopping all agents, replacing the cookie on
every node, and restarting; the command rolls back on failure. Until all
nodes share the cookie the cluster is partitioned, so treat rotation as
planned maintenance.

## Restore drill (recommended, quarterly)

1. Take a scratch machine (or container) and apply the cluster config for a
   node that is currently **down** in your deployment.
2. Restore the cookie from backup.
3. Confirm the node joins and the reconciler converges its services.
4. Confirm `cluster doctor` reports no actionable classes.
5. Record the wall-clock time from power-on to "node active, services at
   replicas" — that number is your measured RTO for a lost node.

See [Operations](OPERATIONS.md) for the operator command surface and
[Alerting](ALERTING.md) for being told when any of this goes wrong.
