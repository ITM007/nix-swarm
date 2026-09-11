# Nix-Swarm

Nix-Swarm is a code-first orchestrator for systemd services on small NixOS clusters. Nix owns desired state, systemd owns processes and resources, and the BEAM owns membership, deterministic placement, supervision, and reconciliation.

It is intentionally not a container runtime, storage system, overlay network, or general-purpose scheduler.

## What it provides

- declarative nodes, replicas, allowed-node placement, and draining
- leaderless placement and failover between configured BEAM peers
- idempotent systemd reconciliation and durable local observations in DETS
- native NixOS deployment, sequential health-gated rollout, and rollback
- a read-only Phoenix web UI for status, placement, metrics, and bounded logs
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
nix-swarm cluster status --source . --target nix-swarm@node-a
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

## Local development environment

The repository includes a one-command development workflow for the Docker
integration cluster and the read-only Phoenix web UI. It requires a running
Docker daemon and a running systemd user manager. From the repository root:

```bash
nix develop --command nu scripts/dev.nu up
```

When startup completes, open:

```text
http://nix-swarm-dev.localhost:4100/
```

The workflow starts `node-a`, `node-b`, `node-c`, and `operator` through
`scripts/docker-stack`, then runs Phoenix and an SSH stream-local forward as
transient `systemd --user` services. Phoenix reads the forwarded local socket;
runtime sockets and generated web secrets live under `$XDG_RUNTIME_DIR`, outside
the Nix path-flake source, and the Docker query socket is not exposed as a host
TCP service. The development
hostname is intentionally separate from `localhost` so its Phoenix session
cookie cannot replace a normal local web session, and it uses a dedicated
`_nix_swarm_dev_web_key` cookie name as a second isolation barrier. The Docker
image build runs in a bounded `nix-swarm-dev.slice` user service with serialized,
core-limited Nix builds so it cannot take down the graphical session under
memory pressure. The NixOS nodes use private cgroup namespaces and are not
privileged containers, so their systemd/logind processes cannot access the
host's TTY, DRM, or input devices. The web UI remains
loopback-only and receives no BEAM cookie or deployment credentials.

Useful commands:

```bash
nix develop --command nu scripts/dev.nu status
nix develop --command nu scripts/dev.nu logs
nix develop --command nu scripts/dev.nu down
```

`down` stops the Phoenix and SSH services, removes the local forwarded socket,
and stops the Docker containers while preserving named cluster state volumes.
Use `reset` only when the harness state and generated development secrets should
also be removed:

```bash
nix develop --command nu scripts/dev.nu reset
```

The transient user units are named `nix-swarm-dev-<project>-web.service` and
`nix-swarm-dev-<project>-tunnel.service`. Their output is available through
`scripts/dev.nu logs` or `journalctl --user`.

## Network and trust model

Agents use distributed Erlang on TCP `4369` and fixed port `4370`. Keep those ports off public and untrusted interfaces; expose them only on a trusted private interface, or on an encrypted overlay such as WireGuard, Tailscale, or NetBird when peers cross networks. The NixOS module refuses an unscoped `openFirewall = true`.

Operators need only SSH. Set `operatorUsers = [ "alice" ];` on each node, then use `--ssh-host alice@node-a`; root also works. Read-only CLI commands cannot mutate the cluster.

Configure service ports, routing, and credentials through ordinary NixOS modules.
For optional edge routing, configure Caddy with the standard `services.caddy`
NixOS module, declare `caddy.service` as a one-replica Nix-Swarm service on an
explicit edge node, and list static candidate backends with Caddy active health
checks. Nix-Swarm deploys the user-authored Nix generation but never edits a
Caddyfile or calls the Caddy Admin API. Use native systemd credentials or a
NixOS secret-management module for secrets.

## Documentation

- [Getting started](docs/GETTING_STARTED.md)
- [Configuration](docs/CONFIG_REFERENCE.md)
- [Bootstrap contract](docs/BOOTSTRAP.md)
- [Operations](docs/OPERATIONS.md)
- [Security](docs/SECURITY.md)
- [Stateful services](docs/STATEFUL_SERVICES.md)
- [Backup and recovery](docs/BACKUP_RECOVERY.md)
- [Optional ingress](docs/INGRESS.md)
- [Alerting](docs/ALERTING.md)
- [Read-only web UI](docs/WEB_UI.md)
- [Development and tests](docs/DEVELOPMENT.md)
- [End-to-end testing listing](docs/TESTING.md)
- [Docker systemd integration harness](docs/DOCKER.md)
- [Product scope](docs/SWARM_PARITY.md)
- [Migration to v1.0](docs/MIGRATING_TO_1.0.md)
- [Release and support policy](docs/RELEASE.md)
