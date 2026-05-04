# Operations guide

## Inspecting the cluster

Launch the TUI with:

```bash
swarm
```

The Dashboard, Map, Machines, Services, and Logs views show the same remote API snapshot from the target node. Placement diagnostics identify services that cannot place because constraints match no nodes or eligible nodes are offline.

## Applying config changes

Use the dry-run flow before applying changes:

1. Edit `cluster/cluster.nix`, `cluster/services/*.nix`, or `machines/*.nix`.
2. Press `y` in the TUI to preview the deployment.
3. Press `p` to apply after reviewing the planned commands.

The deploy helper validates machine modules before remote mutation, syncs the managed source tree over SSH, and runs `nixos-rebuild switch` on each target host sequentially. If a rebuild fails, Nix-Swarm reports the failure and leaves recovery to the operator; it does not automatically restore the remote tree backup or roll back system generations in v1.

## Updating running nodes

Use the update flow when the package or source code changes. Nix-Swarm records pre-update versions, runs deployment, then waits for targeted nodes to report one converged version.

If convergence fails, the error reports the versions each target node last reported. Retry after fixing the failed node or use host targeting to limit the next rollout.

## Failure modes

| Symptom | Likely causes |
|---|---|
| Target cannot connect | cookie mismatch, blocked `4369/4370`, wrong longname, DNS/routing issue |
| Service has unowned slots | no live node satisfies constraints, eligible node offline |
| Multiple replicas on one node | replicas exceed eligible live nodes; multi-replica services need slot-distinct units and ports |
| Apply fails on one host | SSH auth, sudo, Nix evaluation, rebuild failure |
| Mixed versions after update | one or more nodes did not restart into the new generation |

Nix-Swarm is leaderless. During network partitions, separate partitions may temporarily over-replicate stateless services. They reconverge when connectivity returns.

Manual service start/stop actions are temporary in-memory overrides. Use Nix config changes, including `replicas = 0`, for durable service state.
