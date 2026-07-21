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

From the starter directory:

```bash
# Replace the placeholder with this node's real hardware configuration.
ssh root@node-a nixos-generate-config --show-hardware-config \
  > machines/hardware-configuration.nix

nix flake lock
nix-swarm cluster plan --source .
nix-swarm cluster init --source . --yes
nix-swarm cluster doctor --source . --target nix-swarm@node-a
nix-swarm --source . --target nix-swarm@node-a
```

`cluster init` creates one strong local cookie, installs it on the configured root SSH hosts with mode `0400`, evaluates every NixOS closure, and activates the cluster. Use declarative secret provisioning instead if root SSH is unavailable.

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
- [Operations](docs/OPERATIONS.md)
- [Security](docs/SECURITY.md)
- [Development and tests](docs/DEVELOPMENT.md)
- [Product scope](docs/SWARM_PARITY.md)
- [Migration to v1.0](docs/MIGRATING_TO_1.0.md)
- [Release and support policy](docs/RELEASE.md)
