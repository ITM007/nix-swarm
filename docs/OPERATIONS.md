# Operations

## Bootstrap boundary

Nix-Swarm starts with a target that is **already running NixOS**. Before any
operator command, verify SSH host identity and public-key authentication,
root or passwordless noninteractive privilege, supported architecture and disk
space, trusted private-network reachability, and a complete `.nix` inventory.
`cluster apply` is the first Nix-Swarm mutation; it runs preflight and bootstrap
before activation. Installing NixOS, partitioning disks, and hardware or
firmware setup remain user-owned preparation and are not release gates.

## Read operations

```bash
nix-swarm cluster doctor --target nix-swarm@node-a
nix-swarm cluster status --target nix-swarm@node-a
nix-swarm service logs --name example-web --target nix-swarm@node-a --lines 100
nix-swarm --target nix-swarm@node-a
```

Use `--ssh-host user@host` when the SSH destination differs from the BEAM target name. Operators need membership in `services.nix-swarm.operatorGroup` through `operatorUsers`; root is also able to query.

## Apply a change

```bash
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
```

All closures are built before mutation. Deployment is always sequential: one host
at a time, with a 120-second health gate requiring two consecutive healthy
samples. The final batch also requires one digest and no placement errors. A
failed batch always attempts rollback of every host attempted so far.

For deliberate maintenance, target selected hosts with
`--hosts root@node-a,root@node-b`. This does not change the sequential policy.

## Optional Caddy edge

Caddy is not built into Nix-Swarm. Configure it in a user-owned NixOS module
with `services.caddy`, enable it only on an explicitly chosen edge machine, and
declare that machine as the only `allowedNodes` entry for the generic
`caddy.service` Nix-Swarm service. Keep all routing and TLS policy in Nix.

For basic stateless HTTP services, list every valid node/slot endpoint in the
Caddy `reverse_proxy` block and enable active health checks. Service slots use
stable ports; when placement moves a slot, Caddy's health checks stop sending
traffic to the old endpoint and begin using the healthy endpoint without
Nix-Swarm editing any file.

Example workflow:

```bash
$EDITOR examples/config/services/caddy-edge.nix
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
nix-swarm cluster status --target nix-swarm@example-node-a.local
```

Nix-Swarm deploys Caddy as part of the normal NixOS generation and rollback. It
does not watch Caddy files, call the Caddy Admin API, provide a virtual IP, or
replicate Caddy certificate state. If the edge node fails, backend agents may
continue running but external HTTP traffic remains unavailable until DNS,
router forwarding, or an operator-managed replacement edge is available.

## Install or rotate the cluster credential

```bash
nix-swarm cluster credentials --source . --yes
nix-swarm cluster credentials --source . --rotate-credentials --yes
```

Enrollment is idempotent when the remote fingerprint already matches. It installs
only missing credentials and refuses to overwrite a different remote cookie.
Rotation generates a new local cookie, stages it on every host, stops all agents,
switches the credentials, restarts the agents, verifies they are active, and
restores the previous credential if the coordinated operation fails. Use rotation
as a maintenance operation and keep BEAM ports restricted during it. Prefer
provisioning `/etc/nixos/nix-swarm/secrets/nix-swarm.cookie` through an existing
sops-nix or agenix setup.

## Update Nix-Swarm everywhere

```bash
nix-swarm cluster upgrade --source . --yes
```

This updates only the `nix-swarm` flake input, validates the new closures, and performs the normal health-gated rollout. Commit the resulting `flake.lock`. Upgrade the local profile separately with `nix profile upgrade operator`.

## Drain, disable, and rollback

Set `nodes.<name>.availability = "draining";` and apply to move placements off a node. Then use `"maintenance"` before taking it offline so membership gates exclude it. Set a service's `replicas = 0;` to stop it declaratively.

```bash
nix-swarm cluster rollback --source . --yes
```

Rollback activates each target's previous NixOS generation and runs the same health gate.

## Troubleshooting

| Symptom | Check |
|---|---|
| Operator query denied | SSH user is in `nix-swarm-operators`; reconnect after group changes |
| Query helper missing | node uses the current cluster package and `nix-swarmd` is active |
| Peers do not join | matching cookies, resolvable node names, private-interface ports `4369/4370` |
| Agent will not stop a unit | config digests differ; finish or roll back the Nix deployment |
| Rollout health gate fails | `systemctl status nix-swarmd`, cluster status, placement diagnostics, workload unit journal |
| SSH failure | known host key and noninteractive root/sudo authentication |

## Phase 5 diagnostics and context

`cluster doctor` and the read-only TUI share one normalized operator context for
source paths, machine/service directories, cluster file, target, and SSH host.
The context is ephemeral; Git and evaluated Nix remain authoritative.

Diagnostics identify actionable classes including unknown or unpinned SSH host
keys, failed key authentication, interactive sudo, wrong architecture, low disk,
non-NixOS targets, missing `nix-swarm-query`, missing/inactive `nix-swarmd`,
private peer-port failures, protocol incompatibility, credential mismatch, and
configuration digest drift. Fix the reported prerequisite and rerun `doctor`,
then `cluster plan` and explicit `cluster apply`.

The TUI is read-only. It never writes topology, service, credential, or plan
artifacts.

Useful target-side commands:

```bash
systemctl status nix-swarmd
journalctl -u nix-swarmd -n 100 --no-pager
systemctl show nix-swarmd -p User,MemoryCurrent,TasksCurrent
```
