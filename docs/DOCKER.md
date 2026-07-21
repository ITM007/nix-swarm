# Docker systemd integration harness

This repository includes a development-only three-node NixOS/Compose harness.
It is intended for testing Nix-Swarm's BEAM membership, systemd reconciliation,
restricted SSH queries, durable state, and failure behavior without provisioning
three physical machines.

It is not a production deployment model. Each node runs NixOS systemd as PID 1
inside a privileged Docker container. Docker shares the host kernel, cgroup
implementation, and Docker networking, so a NixOS VM remains the authoritative
test for boot, kernel, firewall, and native NixOS activation behavior.

## Requirements

- x86_64 Linux
- Nix with flakes enabled
- Docker Engine and Docker Compose v2, with direct socket access or
  noninteractive `sudo docker` access
- `ssh-keygen`, `od`, and `tr` on the host

The images are built from the local checkout, so run the commands from this
repository and expect a first build to download NixOS and BEAM dependencies.

## Start the cluster

```bash
./scripts/docker-stack up
```

The first run creates ignored development-only material under
`docker/nixos/secrets/`: an Erlang cookie, an SSH key pair, and an SSH
`known_hosts` file. The same cookie is mounted into all three nodes, while the
private key is mounted only into the operator container.

Useful commands:

```bash
./scripts/docker-stack status
./scripts/docker-stack query cluster-status
./scripts/docker-stack query cluster-members
docker compose exec node-a systemctl status nix-swarmd.service
docker compose exec node-a systemctl status demo@0.service
docker compose exec node-a journalctl -u nix-swarmd.service --no-pager -n 100
```

The demo workload is a three-replica Python HTTP service. Nix-Swarm places the
replicas across the three nodes, and systemd owns their lifecycle. Each node's
container port `8080` is mapped to host ports `8081`, `8082`, and `8083`; a
replica may not be present on every mapped port at every moment because
placement is deliberate.

To exercise recovery, stop one node and observe membership and placement:

```bash
docker compose stop node-b
./scripts/docker-stack query cluster-members
docker compose start node-b
```

To test durable state across a restart, use `docker compose restart node-a`.
Use `./scripts/docker-stack reset` when you want to discard the three named
state volumes as well as the containers.

## What this validates

- real Erlang distribution between three independent BEAM releases
- real systemd unit start/stop/readiness ownership inside each node
- systemd watchdog and `Type=notify` startup
- local query sockets reached through SSH from a separate operator container
- DETS operational state on persistent Docker volumes
- node loss and rejoin behavior
- x86_64 package/image assembly from the current checkout

## What it does not validate

- a separate kernel or a real NixOS boot sequence
- host firewall policy or WireGuard/Tailscale routing
- native `nixos-rebuild` activation and rollback over SSH
- production secret management, storage, or backup behavior

Run the NixOS VM check and a real staging rollout before treating a release as
production-ready.
