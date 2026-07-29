# Getting started

## 1. Create a working tree

```bash
nix profile add github:ITM007/nix-swarm#operator
nix-swarm --help
cd ~/.config/nix-swarm
```

The packaged starter is a prepared-machine, one-node flake with one example
systemd service and optional Caddy edge routing. Commit the directory to Git
after adapting it.

## 2. Prepare and adapt the node

Nix-Swarm assumes the target is already running NixOS. Edit these values:

- `flake.nix`: system architecture and flake inputs;
- `cluster.nix`: BEAM node name, deployment host, NixOS configuration name, and
  service placement;
- `machines/node-a.nix`: hostname, deployment public key, and the original
  `system.stateVersion`;
- `machines/hardware-configuration.nix`: the real hardware and filesystem
  configuration from the target.

Capture hardware configuration from the prepared target:

```bash
ssh root@node-a nixos-generate-config --show-hardware-config \
  > machines/hardware-configuration.nix
nix flake lock
```

Use a resolvable short name such as `nix-swarm@node-a`, or a resolvable FQDN on
every peer. Do not mix short and long distributed-Erlang names.

## 3. Review and apply

Pre-populate SSH host keys, then use the explicit plan/apply workflow:

```bash
ssh -o StrictHostKeyChecking=yes root@node-a true
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
```

`cluster apply` is the first Nix-Swarm mutation. It evaluates and builds the
NixOS closures, enrolls only a missing cookie when authorized, activates the
configuration, and verifies convergence. The local cookie is ignored by Git.

## 4. Inspect

```bash
nix-swarm cluster doctor --source . --target nix-swarm@node-a
nix-swarm cluster status --source . --target nix-swarm@node-a
nix-swarm service logs --source . --name example-web --target nix-swarm@node-a
nix-swarm --source . --target nix-swarm@node-a
```

For a non-root operator, declare `operatorUsers = [ "alice" ];` on every node
and pass `--ssh-host alice@node-a`.

## 5. Add services and nodes

Define each service in Nix and provide its matching systemd unit in a normal
NixOS module:

```nix
services.nix-swarm.services.worker = {
  replicas = 2;
  unitTemplate = "worker@%{slot}.service";
  allowedNodes = [ "nix-swarm@node-a" ];
};
```

Nix-Swarm does not create service files or maintain mutable service state. For
additional nodes, add a `nixosConfigurations` output, a machine module, matching
`peers`/`nodes` entries, and the corresponding deployment manifest metadata.

## 6. Optional Caddy edge routing

The starter includes a user-owned Caddy module. Edit
`services/caddy-edge.nix` to change the site, TLS, or backend policy. Caddy is a
normal NixOS service and Nix-Swarm manages its placement as
`caddy.service` on the declared edge node. Candidate backends use Caddy health
checks; Nix-Swarm never edits the Caddy configuration or calls its Admin API.

Apply Caddy edits through the same reviewed workflow:

```bash
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
```

The starter keeps Caddy local to the single prepared node. For multi-node
routing, copy the topology from `examples/config`, list stable candidate
endpoints, and expose backend ports only on the trusted private interface.
