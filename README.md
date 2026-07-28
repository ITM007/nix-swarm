# Nix-Swarm

Nix-Swarm is a code-first orchestrator for systemd services on small NixOS clusters. Nix owns desired state, systemd owns processes and resources, and the BEAM owns membership, deterministic placement, supervision, and reconciliation.

It is intentionally not a container runtime, storage system, overlay network, or general-purpose scheduler.

## What it provides

- declarative nodes, replicas, labels, constraints, preferred nodes, and draining
- leaderless placement and failover between configured BEAM peers
- idempotent systemd reconciliation and durable local observations in DETS
- native NixOS deployment, canaries, health-gated batches, and rollback
- a read-only TUI for status, placement, metrics, and bounded journald logs
- unprivileged agents with exact systemd-unit authorization
- SSH operator access through a restricted local Unix socket; operators never receive the BEAM cookie

## Install

Run without installing:

```bash
nix run github:ITM007/nix-swarm -- --help
```

Install the operator:

```bash
nix profile add github:ITM007/nix-swarm#operator
```

The first `nix-swarm` launch creates a starter flake at `~/.config/nix-swarm`. You can also copy [`examples/starter`](examples/starter) into a Git repository.

## Start a cluster

Nix-Swarm starts with a target that is **already running NixOS**. Before using the
operator, prepare each machine yourself: review and pin its SSH host key, enable
public-key SSH and root or passwordless noninteractive privilege, confirm the
supported architecture and enough disk space for Nix closures, connect peers on a
trusted private network, and declare the node, deployment host, and complete
NixOS configuration in your `.nix` inventory.

From the prepared starter directory:

```bash
nix flake lock
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
nix-swarm cluster doctor --source . --target nix-swarm@node-a
nix-swarm --source . --target nix-swarm@node-a
```

`cluster apply` is the first Nix-Swarm mutation. It performs preflight, builds
closures, enrolls only a missing cookie, activates NixOS, and verifies the
cluster. Nix-Swarm does not install NixOS, partition disks, or run
`nixos-anywhere`; those are optional, user-owned preparation choices outside the
product and release gates. Use declarative secret provisioning instead if root
SSH is unavailable.

The starter flake also exposes `nixosConfigurations.<node>-hardened` and the
flake exposes `nixosModules.hardened`. Select the hardened machine output in
your deployment manifest when you want the minimal hardened host baseline. It
requires a real hardware configuration, deployment public key, private
overlay interface, and separately provisioned cookie; review the profile's
resource limits against the node workload before rollout.

## Normal workflow

Edit Nix, review, then apply:

```bash
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
```

Update the application input and roll it across the cluster:

```bash
nix-swarm cluster upgrade --source . --yes
```

Update only the local operator profile:

```bash
nix profile upgrade operator
```

Rollback uses the previous NixOS generation:

```bash
nix-swarm cluster rollback --source . --yes
```

## Network and trust model

Agents use distributed Erlang on TCP `4369` and fixed port `4370`. Keep those ports closed on public/LAN interfaces and expose them only through a trusted encrypted overlay such as WireGuard or Tailscale. The NixOS module refuses an unscoped `openFirewall = true`.

Operators need only SSH. Set `operatorUsers = [ "alice" ];` on each node, then use `--ssh-host alice@node-a`; root also works. The TUI cannot mutate the cluster.

Service `settings` are public metadata rendered into the Nix store. Never put credentials there; use native systemd credentials or a NixOS secret-management module.

## Documentation

- [Getting started](docs/GETTING_STARTED.md)
- [Configuration](docs/CONFIG_REFERENCE.md)
- [Bootstrap contract](docs/BOOTSTRAP.md)
- [Preparing a NixOS target](docs/PROVISIONING.md)
- [Operations](docs/OPERATIONS.md)
- [Security](docs/SECURITY.md)
- [Development and tests](docs/DEVELOPMENT.md)
- [End-to-end testing listing](docs/TESTING.md)
- [Docker systemd integration harness](docs/DOCKER.md)
- [Product scope](docs/SWARM_PARITY.md)
- [Migration to v1.0](docs/MIGRATING_TO_1.0.md)
- [Release and support policy](docs/RELEASE.md)
