# Getting started with Nix-Swarm

Nix-Swarm is for small, trusted NixOS clusters where Nix defines desired state, systemd runs services, and each node independently computes placement.

## Minimal workflow

1. Generate one strong Erlang cookie and install it on every managed node outside the Nix store:

   ```bash
   tr -dc 'A-Za-z0-9_.-' </dev/urandom | head -c 48 > nix-swarm.cookie
   install -m 600 -o root -g root nix-swarm.cookie /etc/nixos/nix-swarm/secrets/nix-swarm.cookie
   ```

2. Add the Nix-Swarm package to your operator workstation and import the NixOS module on each managed node.

3. Keep shared topology in `cluster/cluster.nix`, machine-specific runtime setup in `machines/*.nix`, and backing service modules in `cluster/services/*.nix`.

4. Launch the operator TUI from a workstation that can reach one cluster node:

   ```bash
   export NIX_SWARM_COOKIE_FILE=/path/to/nix-swarm.cookie
   swarm --target nix-swarm@example-node-a.local
   ```

5. Use the TUI to inspect health, view placement, read logs, dry-run config changes, apply config changes, and roll out code/config updates.
6. Keep the editable config tree in `~/.config/nix-swarm`, or point `--source` at a Git checkout when you want version-controlled cluster changes.

## Network requirements

Nix-Swarm uses distributed Erlang. It should run only on a trusted LAN or private overlay/VPN.

| Traffic | Default port | Direction |
|---|---:|---|
| EPMD discovery | `4369/tcp` | operator to node, node to node |
| Erlang distribution | `4370/tcp` | operator to node, node to node |
| SSH deploy/update | `22/tcp` | operator to deploy hosts |

If `services.nix-swarm.openFirewall = true`, the NixOS module opens the EPMD and distribution ports. Set `firewallInterfaces` to restrict those ports to a management interface.

## First service

A Nix-Swarm service has two pieces:

- a placement entry under `services.nix-swarm.services.<name>` in `cluster/cluster.nix`
- a NixOS service definition under `cluster/services/<name>.nix`

For one replica, the default unit template is `%{service}.service`. For multiple replicas, it is `%{service}@%{slot}.service`, so the backing NixOS module must define a matching template unit such as `systemd.services."example-web@"`. If a service exposes ports, each slot needs a distinct port because placement may wrap and run more than one slot on a node when replicas exceed live eligible nodes.

If constraints match no nodes, or if eligible nodes are offline, cluster status now reports placement diagnostics so the TUI/API can explain why slots have no owner.

Set `replicas = 0` to disable a service declaratively. Nix-Swarm schedules no slots and best-effort stops units it previously owned while the daemon still remembers them.

## Troubleshooting quick checks

```bash
nc -vz example-node-a.local 4369
nc -vz example-node-a.local 4370
ssh -o BatchMode=yes root@example-node-a.local true
journalctl -u nix-swarmd -n 100 --no-pager
```

Common causes of launch failures are cookie mismatch, blocked EPMD/distribution ports, wrong longname/shortname mode, or an operator node name that the target cannot route back to.
