# Testing

This repository supports x86_64 Linux development and NixOS targets. Nix-Swarm
starts at an SSH-reachable, user-prepared NixOS machine; installation,
partitioning, firmware, and storage preparation are outside the product test
boundary.

## Local quality gate

Run from the repository root, preferably inside the pinned development shell:

```bash
nix develop --command mix format --check-formatted
nix develop --command mix clean
nix develop --command mix compile --warnings-as-errors
nix develop --command mix hex.audit
nix develop --command mix test --warnings-as-errors --cover
nix flake check --print-build-logs
```

The aggregate coverage gate is currently 65%. New control-plane, placement,
deployment, security, and reconciliation behavior should include focused tests.

## Nix checks

The flake evaluates and checks the following relevant outputs:

| Check | Coverage | Command |
|---|---|---|
| `nixos-module` | Complete NixOS module evaluation and assertions | `nix flake check --print-build-logs` |
| `starter-syntax` | Prepared one-node starter, including its Caddy module | `nix build .#checks.x86_64-linux.starter-syntax --no-link --print-build-logs` |
| `example-config-caddy` | Two-node example with edge-only Caddy placement and static candidate backends | `nix build .#checks.x86_64-linux.example-config-caddy --no-link --print-build-logs` |
| `nixos-vm` | Native NixOS activation, hardened daemon, systemd notify, DETS, and query authorization | `nix build .#checks.x86_64-linux.nixos-vm --no-link --print-build-logs` |
| `caddy-vm` | Nix-defined Caddy, managed `caddy.service`, HTTP forwarding, active backend health checks, and no Nix-Swarm-generated Caddyfile | `nix build .#checks.x86_64-linux.caddy-vm --no-link --print-build-logs` |
| `operator-smoke` | Packaged `--help`, `--version`, and `cluster plan` entry points | `nix build .#checks.x86_64-linux.operator-smoke --no-link --print-build-logs` |

The Caddy VM uses one explicit edge node and static candidate backend
endpoints. It does not validate multi-edge failover, DNS failover, certificate
replication, or production router behavior.

## Integration harness

The development-only Docker harness runs three NixOS systemd nodes in
privileged containers:

```bash
./scripts/docker-stack up
./scripts/docker-stack status
./scripts/docker-stack query cluster-status
./scripts/docker-stack reset
```

It validates BEAM membership, systemd reconciliation, restricted SSH queries,
DETS persistence, node loss, and node rejoin. It does not validate a separate
kernel, native NixOS boot, real firewall/overlay networking, SSH deployment and
rollback, production secrets, or storage behavior. Run the NixOS VM checks and a
real staging rollout before treating a release as production-ready.

## Deployment and release evidence

Focused deployment-model tests cover closure-before-mutation, preflight,
sequential rollout, readiness gates, attempted-host rollback, and draining or
maintenance nodes:

```bash
nix develop --command mix test \
  test/nix_swarm_deploy_state_machine_test.exs \
  test/nix_swarm_deploy_rollout_property_test.exs \
  test/nix_swarm_deploy_rollout_test.exs \
  test/nix_swarm_deploy_preflight_test.exs --seed 0
```

The release evidence collector can run the complete configured gate and records
unavailable tools explicitly:

```bash
nix develop --command mix run --no-start scripts/collect_release_evidence.exs \
  -- --output _build/release-evidence.txt
```

Release runs must use a clean checkout and require the Docker runtime when the
release procedure requests it. Never report an unavailable VM, Docker, or
staging check as passed.

## Manual staging acceptance

A prepared multi-node NixOS environment should additionally verify:

- strict SSH host-key checking and credential enrollment/rotation;
- `cluster plan` followed by explicit `cluster apply`;
- service readiness, sequential rollout, failed activation, and rollback;
- node draining, maintenance, reboot, loss, and rejoin behavior;
- private-only BEAM ports `4369` and `4370`;
- Caddy edge-node failure and operator-managed replacement behavior;
- application-owned backup, replication, and rollback for stateful services.
