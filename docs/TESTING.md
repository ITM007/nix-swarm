# Nix-Swarm Testing Listing

This document is the end-to-end test inventory for Nix-Swarm. It is written for
release candidates and for operators emulating a small NixOS cluster locally.
The Docker harness runs NixOS systemd as PID 1 in privileged containers. It is
useful for live BEAM, systemd, SSH, query-socket, placement, and persistence
checks, but it does not replace the NixOS VM test or a real staging rollout.

## Test Layers

Run the layers in this order. A later layer is not a substitute for an earlier
one, and a Docker pass must not be reported as native NixOS boot coverage.

| Layer | Coverage | Command or entry point |
| --- | --- | --- |
| Static and unit | Formatting, compiler inference, parsers, placement, deployment decisions, security contracts | `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test --warnings-as-errors --cover` |
| Nix evaluation | Packages, module assertions, starter syntax, deployment manifest evaluation | `nix flake check --print-build-logs` |
| NixOS VM | Real NixOS activation, hardened daemon, systemd notify, DETS, query authorization | `nix build .#checks.x86_64-linux.nixos-vm --no-link --print-build-logs` |
| Docker live | Three independent BEAM nodes, systemd workload ownership, SSH query path, failure and rejoin | `./scripts/docker-stack up` |
| Staging | Kernel, firewall, native `nixos-rebuild`, real SSH, rollback, secret provisioning, production limits | Separate NixOS machines |

## Baseline Gate

### Environment checks

Required host capabilities:

- x86_64 Linux
- Nix with flakes enabled and access to the Nix daemon
- Docker Engine and Compose v2 with access to the Docker socket
- `ssh-keygen`, `od`, `tr`, `curl`, and a pseudo-terminal for TUI testing
- Elixir 1.20.x and OTP compatible with the project, preferably from `nix develop`

The installed Elixir `1.20.0-rc.6` was rejected by Mix because `mix.exs`
declares `~> 1.20`. The pinned shell supplied Elixir `1.20.2` on OTP 28 and is
the supported way to avoid this toolchain mismatch.

### Required commands

```bash
nix develop --command bash -c 'mix format --check-formatted && mix clean && mix compile --warnings-as-errors && mix test --warnings-as-errors --cover'
nix flake check --print-build-logs
nix build .#checks.x86_64-linux.nixos-vm --no-link --print-build-logs
nix build .#checks.x86_64-linux.operator-smoke --no-link --print-build-logs
nix build .#checks.x86_64-linux.starter-syntax --no-link --print-build-logs
```

Observed on 2026-07-22:

- Mix gate: `210 passed`, total coverage `66.30%`.
- Flake check: all outputs and NixOS module checks passed.
- Explicit VM, operator smoke, and starter syntax derivations built successfully.
- The Mix suite prints an expected fake-executor `activation failed` message;
  the suite still passes. Keep this output in mind when scanning CI logs.

## Docker Harness Setup

The following commands are run from the repository root. The first build can
download a complete NixOS and BEAM closure.

```bash
./scripts/docker-stack up
# Optional hardened image/profile:
./scripts/docker-stack --profile hardened up
./scripts/docker-stack status
./scripts/docker-stack query cluster-status
docker compose exec node-a systemctl status nix-swarmd.service
```

The harness creates ignored development credentials under
`docker/nixos/secrets/`. Verify that the cookie is shared by the three nodes,
the operator receives only the SSH private key, and the files do not enter Git.

### Live test listing

| ID | Scenario | Procedure | Expected result |
| --- | --- | --- | --- |
| DOCKER-001 | Image assembly | `./scripts/docker-stack up`; repeat with `--profile hardened` | Standard images build by default; the hardened profile builds the three `*-hardened` outputs and loads the hardened image tags. |
| DOCKER-002 | Container health | `docker compose ps` | Three nodes are healthy; operator starts after all nodes. |
| DOCKER-003 | Hardened runtime | `./scripts/docker-stack --profile hardened up`; inspect `systemctl`, `sysctl`, firewall, and `sshd -T` inside node-a | Hardened image runs the daemon as `nix-swarm`, enforces service sandboxing and firewall rules, and applies sysctl/SSH policy. AppArmor and auditd remain host-kernel dependent in Docker. |
| DOCKER-004 | PID 1/systemd | `docker compose exec node-a systemctl is-system-running` | systemd is the container init and units can be queried. |
| DOCKER-005 | Credential seeding | Inspect cookie, authorized keys, and operator mounts | Nodes have the cookie and authorized key; operator has only its private SSH key. |
| CLUSTER-001 | Membership | `./scripts/docker-stack query cluster-status` | Three configured and live nodes, all on release `v0.4.1`. |
| CLUSTER-002 | Placement | Inspect `demo@0`, `demo@1`, `demo@2` on all nodes | Three slots have one owner each, distributed one per node. |
| CLUSTER-003 | Workload health | `systemctl is-active demo@0.service demo@1.service demo@2.service` | Only the assigned slot is active on each node. |
| CLUSTER-004 | HTTP workload | `curl http://127.0.0.1:8081/`, `:8082/`, `:8083/` | Each endpoint returns its node-specific harness text. |
| CLUSTER-005 | Read-only status | `nix-swarm cluster status --target nix-swarm@node-a --ssh-host root@node-a` | Status includes members, versions, services, and diagnostics. |
| CLUSTER-006 | SSH doctor | `nix-swarm cluster doctor --target nix-swarm@node-a --ssh-host root@node-a` | SSH plus restricted Unix-socket query reports `ok`. |
| CLUSTER-007 | Service logs | `nix-swarm service logs --name demo --target nix-swarm@node-a --lines 10` | Bounded journald entries are returned for each owner. |
| CLUSTER-008 | TUI with TTY | Run `nix-swarm --target nix-swarm@node-a` in a pseudo-terminal, quit with `q` | Dashboard renders target, health, nodes, services, and read-only status. |
| CLUSTER-009 | TUI without TTY | `timeout 5 nix-swarm --target ...` with stdin not attached | Exits with `terminal_init_failed`; no hang or mutation. |
| CLUSTER-010 | Query selector | Run `./scripts/docker-stack query cluster-members` | Prints the membership view; `cluster-status` remains the placement/status view. |
| QUERY-001 | Restricted query operations | Exercise overview, members, operator snapshots, service logs, node logs, and cluster logs through `nix-swarm-query` | All supported operations return bounded responses through the Unix socket; unknown nodes and invalid line counts return encoded errors. |
| RECOVERY-001 | Agent restart | `docker compose restart node-a`; inspect `nix-swarmd`, SSH, and DETS | Agent restarts, DETS remains present, and node rejoins. |
| RECOVERY-002 | Restart convergence | Query immediately, then after at least 30 seconds | The configured recovery stabilization window intentionally withholds returning nodes from placement; after stabilization all slots converge. Treat the early no-owner view as a safety state, not as final recovery. |
| RECOVERY-003 | Node loss | `docker compose stop node-b`; wait 15 seconds; query status | Membership drops to two, node-b port fails, and a slot is diagnosed as unowned when only two nodes are eligible for three replicas. |
| RECOVERY-004 | Node rejoin | `docker compose start node-b`; wait for health and recovery stabilization | Node-b rejoins and all three slots return to one owner per node. |
| RECOVERY-005 | Durable state | Hash `/var/lib/nix-swarm/nix-swarm_node-a/operational-state.dets` before and after restart | File survives restart; Docker volume is persistent. The Docker path includes the node suffix. |
| SYSTEMD-001 | Notify readiness | `systemctl show nix-swarmd.service -p Type,User,MainPID` | `Type=notify`, `User=nix-swarm`, and a live BEAM PID. |
| SYSTEMD-002 | Hardening | Inspect ProtectSystem, NoNewPrivileges, PrivateDevices, PrivateTmp, MemoryMax, TasksMax | Hardened settings are present; observed limits were `512M` and `512`. |
| SYSTEMD-003 | Unit lifecycle | Restart an assigned `demo@N.service` and query its state/logs | systemd owns the process and it returns to active. |
| SECURITY-001 | Cookie disclosure | Search daemon `/proc/$PID/cmdline` and `/proc/$PID/environ` for cookie material | Cookie is absent from argv and environment. |
| SECURITY-002 | Operator isolation | `test ! -e /etc/nix-swarm.cookie` in operator; inspect env and mounts | Operator does not receive the BEAM cookie. |
| SECURITY-003 | Query socket outsider | `runuser -u nobody -- nix-swarm-query Y2x1c3Rlci1tZW1iZXJz` | Helper returns an encoded `access` error, not cluster data. |
| SECURITY-004 | Query socket authorized user | Run the same helper as `nix-swarm` or an operator-group user | Authorized identity receives a response. |
| SECURITY-005 | Malformed protocol | Run helper with empty, invalid base64, truncated, and missing arguments | Invalid requests return encoded `unsupported_request`; missing argument exits `64`. |
| SECURITY-006 | Unit-name injection | Use names such as `../../etc/passwd`, `foo;rm`, and `--root=/etc/passwd`; request logs for an unknown service | Executor and CLI validation reject destructive or unknown service names with a nonzero error. |
| SECURITY-007 | SSH argument injection | Put shell metacharacters in `--target` and `--ssh-host` | CLI rejects both as unsupported characters; no command executes. |
| SECURITY-008 | Peer ports | Inspect `ss -ltnp` and Compose port mappings | BEAM listens on 4369/4370. The harness maps these to the host for testing; never expose this Compose setup as production networking. |
| CLI-001 | Help/version | `nix-swarm --help`; `nix-swarm --version` | Side-effect-free help and a semantic version are printed. |
| CLI-002 | Templates | `nix-swarm service list` | `custom` and `web` templates are listed without evaluating deployment metadata or emitting a Nix daemon/experimental-feature warning. |
| CLI-003 | Confirmation gates | Run `cluster ensure`, `credentials`, `init`, `apply`, `upgrade`, and `rollback` without `--yes` | Each refuses before machine mutation. |
| CLI-004 | Numeric bounds | Test lines `0/1001`, refresh `99/600001`, replicas `-1/129`, max-unavailable `0/129`, and timeout outside range | Each exits nonzero with a range error. |
| CLI-005 | Unknown input | Unsupported option and unknown command | Nonzero exit with actionable error text. |
| CLI-006 | JSON option | `nix-swarm cluster status ... --json`; also test members and service logs | Emits one valid JSON document on stdout with no transient VM noise. Other commands reject `--json` instead of silently ignoring it. |
| CLI-007 | Unsafe mutator | `nix-swarm cluster rebuild --source /invalid` and repeat with `--yes` | Refuses before evaluation without `--yes`; with confirmation it follows the normal deployment boundary and reports invalid source errors without target mutation. |
| CONFIG-001 | Generate service | In a temporary starter copy, `service create --name alpha --template web` | Creates `services/alpha.nix` with a safe unit template. |
| CONFIG-002 | Duplicate generation | Repeat `service create` and `service add` for the same name | Refuses without overwriting the existing module. |
| CONFIG-003 | Add service | `service add --name worker --template custom --replicas 2 --constraints apps --constraints ssd` | Creates a self-contained module and tells the user to import it; it does not silently rewrite `cluster.nix`. |
| CONFIG-004 | Invalid names | Try `../escape`, `bad/name`, `bad..name`, empty, and punctuation | Rejects unsupported names and traversal. |
| CONFIG-005 | Unknown template | `service create --template missing` | Nonzero error lists available templates. |
| DEPLOY-001 | Root source | `nix-swarm cluster plan --source .` | Expected failure: repository root has a manifest but no matching `nixosConfigurations` output. |
| DEPLOY-002 | Starter source | `nix-swarm cluster plan --source examples/starter` | Expected failure until placeholder `hardware-configuration.nix` is replaced. |
| DEPLOY-003 | Valid fixture | Run the Nix `operator-smoke` derivation | Help, version, and a valid deployment plan containing `nixos-rebuild` pass. |
| NIXOS-001 | VM check | `nix build .#checks.x86_64-linux.nixos-vm --no-link` | Native NixOS VM validates notify readiness, unprivileged daemon, cookie permissions, query socket, operator allowlist, and DETS. |
| TEARDOWN-001 | Preserve volumes | `./scripts/docker-stack down`; list named volumes | Containers/network stop while named state volumes remain. |
| TEARDOWN-002 | Reset state | `./scripts/docker-stack reset`; list named volumes | Containers and named state volumes are removed. Use only when discarding test state is intended. |

## Failure Injection Matrix

Run each failure with a clean baseline and capture both status output and
`journalctl -u nix-swarmd.service --no-pager -n 100`.

| Injection | What to verify |
| --- | --- |
| Stop one node for less than `failureGraceMs` | No premature movement or duplicate owner is reported. |
| Stop one node beyond `failureGraceMs` | Membership changes and diagnostics identify missing capacity. |
| Restart a node repeatedly | Recovery stabilization prevents immediate flapping placement. |
| Change one node's config digest | Destructive reconciliation is blocked until configuration is consistent. |
| Make a workload unit fail readiness | Health gate reports failure and does not claim a healthy rollout. |
| Make a deployment target unreachable | Batch stops, diagnostics identify SSH/health failure, and auto-rollback is attempted when enabled. |
| Use an invalid cookie length or character | NixOS start script rejects it before the daemon starts. |
| Remove query helper from a target | Doctor reports the missing helper and does not grant arbitrary SSH execution. |
| Fill or corrupt DETS state | Agent reports/recreates state without treating operational observations as desired state. |
| Inject ANSI/control bytes into journald | Operator log output strips terminal control sequences. |
| Exceed log/request bounds | Query protocol rejects the request without unbounded memory or output growth. |

## Evidence Collection

For every run, save the command, exit code, timestamp, and relevant output. A
minimal live evidence bundle is:

```bash
./scripts/docker-stack status
./scripts/docker-stack query cluster-status
docker compose ps
docker compose exec node-a systemctl show nix-swarmd.service -p Type,User,MainPID,MemoryMax,TasksMax
docker compose exec node-a journalctl -u nix-swarmd.service --no-pager -n 100
docker compose exec node-a find /var/lib/nix-swarm -maxdepth 3 -type f -ls
```

Record transient recovery states separately from final convergence. A status
with live peers but no owners during the recovery window is not equivalent to a
stable pass or a stable failure; it needs a timestamp and a follow-up sample.

## Cleanup

Use `down` to preserve state for post-run inspection. Use `reset` only after
capturing evidence. Never commit `docker/nixos/secrets/` or Docker result links.

```bash
./scripts/docker-stack down
# inspect preserved volumes, then:
./scripts/docker-stack reset
git status --short
```

## Coverage Boundaries

The Docker harness does not prove a separate kernel, native NixOS boot, host
firewall policy, WireGuard/Tailscale routing, native `nixos-rebuild` activation,
rollback on a real target, production secret management, storage failure, or
backup recovery. Those cases remain required in the NixOS VM and staging test
plans.
