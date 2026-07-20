# Getting started

## 1. Create a working tree

```bash
nix profile add github:ITM007/nix-swarm#operator
nix-swarm --help
cd ~/.config/nix-swarm
```

The packaged starter is a one-node flake with one example systemd service. Commit this directory to Git after adapting it.

## 2. Adapt the node

Edit these values:

- `flake.nix`: system architecture
- `cluster.nix`: BEAM node name, labels, `deployHost`, and NixOS configuration name
- `machines/node-a.nix`: hostname, BEAM node name, and original `system.stateVersion`

Capture the target's hardware module:

```bash
ssh root@node-a nixos-generate-config --show-hardware-config \
  > machines/hardware-configuration.nix
nix flake lock
```

Use a resolvable short name such as `nix-swarm@node-a`, or a resolvable FQDN on every peer. Do not mix short and long distributed-Erlang names.

## 3. Review and initialize

Pre-populate SSH host keys, then run:

```bash
ssh -o StrictHostKeyChecking=yes root@node-a true
nix-swarm cluster plan --source .
nix-swarm cluster init --source . --yes
```

Initialization securely generates `secrets/nix-swarm.cookie` if absent, installs it on every configured deploy host, and applies the flake. The local cookie is ignored by Git.

## 4. Inspect

```bash
nix-swarm cluster doctor --source . --target nix-swarm@node-a
nix-swarm cluster status --source . --target nix-swarm@node-a
nix-swarm --source . --target nix-swarm@node-a
```

For a non-root operator, declare `operatorUsers = [ "alice" ];` on every node and pass `--ssh-host alice@node-a`.

## 5. Add services and nodes

```bash
nix-swarm service add --source . --name worker --template custom --replicas 2
```

Each placement entry needs a matching NixOS/systemd unit. `service add` creates one self-contained module with the placement declaration and `%{service}@%{slot}.service`; import that generated file from `cluster.nix`. The command never rewrites an existing Nix module.

For additional nodes, add a `nixosConfigurations` output, a machine module, matching `peers`/`nodes` entries, and keep `nixSwarm.deploymentManifest` generated from those configurations. Run BEAM traffic only over a private overlay:

```nix
services.nix-swarm = {
  openFirewall = true;
  firewallInterfaces = [ "wg0" ]; # or tailscale0
};
```

Operators use SSH; only agent-to-agent traffic needs TCP `4369` and `4370`.
