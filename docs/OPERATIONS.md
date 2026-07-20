# Operations

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

All closures are built before mutation. Canaries run one at a time; other hosts use `maxUnavailable` (default `1`). Health must remain strictly `running` for the Nix-defined number of consecutive samples. The final batch also requires one digest and no placement errors. A failed batch rolls back every host attempted so far when `deployment.autoRollback` is enabled.

Target selected hosts with `--hosts root@node-a,root@node-b`; put canaries first with `--canary-hosts root@node-a`.

## Install or rotate the cluster credential

```bash
nix-swarm cluster credentials --source . --yes
nix-swarm cluster credentials --source . --rotate-credentials --yes
```

The first command is enrollment and refuses to overwrite an existing remote cookie. Rotation requires the explicit second form. Prefer provisioning `/etc/nixos/nix-swarm/secrets/nix-swarm.cookie` through an existing sops-nix or agenix setup.

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

Useful target-side commands:

```bash
systemctl status nix-swarmd
journalctl -u nix-swarmd -n 100 --no-pager
systemctl show nix-swarmd -p User,MemoryCurrent,TasksCurrent
```
