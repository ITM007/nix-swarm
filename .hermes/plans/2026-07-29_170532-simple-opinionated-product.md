# Simple Opinionated Nix-Swarm Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Reduce Nix-Swarm to a simple, opinionated systemd service orchestrator for home labs and small businesses, add CPU-and-memory autoscaling and one safe service restart command, and remove unsupported, overlapping, compatibility-only, or unreachable functionality.

**Architecture:** Keep Nix/Git as the only durable desired state, systemd as the process runtime, and the existing leaderless BEAM placement/reconciliation design. Keep the CLI and read-only TUI. Collapse operator mutations onto one deployment path (`plan` → `apply`), expose only the few service and autoscaling fields ordinary users need, and retain safety/validation complexity internally rather than turning it into product options.

**Tech Stack:** Elixir/OTP, NixOS modules, systemd, restricted SSH/query transport, ExUnit, Nix flakes, Docker/NixOS integration harness.

---

## 1. Product decisions

This plan deliberately favors one good path over optionality.

### Supported operator model

- The user prepares an SSH-reachable NixOS machine.
- The user declares machines and services in `.nix` files.
- `cluster plan` previews every durable change.
- `cluster apply --yes` is the only normal mutation path. It performs preflight, missing-only credential enrollment, closure deployment, systemd activation, convergence checks, and automatic rollback.
- `cluster rollback --yes` activates the previous NixOS generation.
- `cluster upgrade --yes` remains one convenience command for updating the Nix-Swarm flake input and applying it. The separate `upgrade prepare` subcommand is removed.
- The CLI and TUI retain read-only status, diagnostics, logs, placement, and metrics.
- One explicit maintenance action is added: `service restart`. It restarts currently assigned units sequentially over the existing privileged SSH deployment channel and verifies systemd readiness after each restart.
- Starting and stopping remain declarative: set `replicas` above zero to run a service and set `replicas = 0` to stop it. Do not add temporary start/stop overrides or another operational state store.
- Moving a service remains declarative: set a node to `draining`, apply, then set it to `maintenance` before taking it offline. Downtime is acceptable; no live migration is promised.
- Autoscaling uses existing declared machines only. It never provisions machines, rewrites Nix, or manages databases/storage.

### Opinionated service model

The public service options after migration should be:

```nix
services.nix-swarm.services.api = {
  replicas = 1;
  unitTemplate = "api@%{slot}.service"; # optional when one replica
  allowedNodes = [ ];                   # empty means every active node

  autoscaling = {
    enable = false;
    minReplicas = 1;
    maxReplicas = 4;
    cpuTargetPercent = 70;
    memoryTargetPercent = 80;
  };
};
```

Fixed internal autoscaling policy:

- sample window: 60 seconds;
- evaluation interval: 10 seconds;
- scale-up cooldown: 30 seconds;
- scale-down cooldown: 300 seconds;
- scale step: one replica;
- scale-down threshold: 70% of each configured target;
- scale up when CPU **or** memory exceeds its target;
- scale down only when CPU **and** memory are below their hysteresis thresholds;
- memory percentage is `MemoryCurrent / MemoryMax`; if systemd reports no finite `MemoryMax`, memory scaling is unavailable for that service and produces a diagnostic rather than silently guessing from host memory;
- enabling autoscaling is the operator's explicit assertion that multiple concurrent instances are safe. Do not add a separate `stateless` option.

### Fixed deployment policy

Remove public rollout tuning and retain one safe policy internally:

- build all closures before mutation;
- update one host at a time;
- wait up to 120 seconds;
- require two consecutive healthy samples;
- always roll back attempted hosts after failure;
- no canary configuration or parallel rollout setting;
- targeted `--hosts` remains for deliberate maintenance, but `--canary-hosts` and `--max-unavailable` are removed.

### Explicit non-goals

- no database, SQLite file, PostgreSQL, volume, or storage management;
- no live migration;
- no automatic VM/machine provisioning;
- no overlay network or routing mesh;
- no consensus database or second desired-state store;
- no mutable TUI controls;
- no arbitrary custom metrics providers;
- no request-rate, latency, queue, disk, or network autoscaling;
- no per-service rollout strategy matrix;
- no temporary service start/stop overrides;
- no NixOS installation, Disko, or `nixos-anywhere` workflow.

---

## 2. Audit findings

### Keep: complexity that protects the simple product

| Area | Why it stays |
|---|---|
| `NixSwarm.Cluster`, `Placement`, and `Reconciler` | These are the core leaderless placement and recovery behavior. Stable hashing remains an internal deterministic spread algorithm, not a user-selectable scheduler. |
| `OperationalState` DETS snapshots | Small node-local observations improve recovery and diagnostics without becoming desired state. |
| restricted query socket and SSH transport | Preserves the important separation between read-only operators and cookie-bearing agents. |
| systemd watchdog and exact-unit polkit rules | Small implementation cost with meaningful reliability/security benefits. |
| telemetry helpers | Tiny internal instrumentation surface; no product options are exposed. |
| preflight, closure-first deployment, health gate, and rollback | Safety is worth internal complexity even when downtime is acceptable. |
| Docker/NixOS/release test harnesses | Development/release complexity does not burden users and prevents false release claims. |
| hardened NixOS module | Useful secure default for small businesses; keep it, but remove installer/Disko examples from the starter. |

### Remove or consolidate

| Current feature | Evidence | Decision |
|---|---|---|
| `cluster init`, `cluster ensure`, `cluster rebuild` | `lib/nix_swarm/cli.ex`, `lib/nix_swarm/cluster/ensure.ex`, and `lib/nix_swarm/cluster/rebuild.ex` all reach the same deployment path; `cluster apply` already bootstraps prepared hosts and enrolls missing credentials. | Remove aliases and modules. Keep only plan/apply. |
| plain `cluster credentials` enrollment | `cluster apply` already enrolls only missing credentials. | Replace with one explicit `cluster credentials rotate --yes` maintenance command. |
| `cluster upgrade prepare` | Adds a second upgrade workflow beside `cluster upgrade`. | Remove; keep one upgrade command. |
| `cluster members` | `cluster status` already contains configured/live membership. | Remove standalone command; preserve membership in status/TUI/JSON. |
| `service create`, `service add`, `service list` template system | `CLI` exposes overlapping scaffolding commands while the packaged starter already provides a complete `.nix` example. | Remove these commands, `NixSwarm.Service.Templates`, and generated service/machine writers. Users copy/edit the starter example. |
| dead mutable TUI paths | `lib/nix_swarm/tui/state.ex` always forces `operator_mode: :read_only`, while `tui.ex` still contains add/edit/delete files, rollout confirmation, deployment jobs, and mutable action state. | Delete all unreachable mutable code and dependencies; keep views, navigation, refresh, search, logs, metrics, and help. |
| `NixSwarm.Update` | Used by unreachable TUI rollout code; duplicates `Deploy`. | Delete after TUI cleanup. |
| ingress compatibility metadata | `nix/nix-swarm/ingress.nix`, `Config.normalize_ingress/1`, API/TUI ingress payloads; docs state it does not configure routing. | Remove entirely. Users configure nginx/HAProxy directly in NixOS. |
| deprecated service `healthcheck` | Display-only and never executed. | Remove option, normalization, warnings, API/TUI display, and migration compatibility. Health remains systemd-derived. |
| arbitrary service `settings` metadata | Public Nix-store metadata mainly supports ingress/TUI display and is not orchestration state. | Remove. Service configuration belongs in the service's own NixOS module. |
| `preferredNodes` | A second, soft placement policy. | Remove. Use `allowedNodes`, draining, or normal deterministic spread. |
| node labels and service `constraints` | Duplicates exact allowlisting for the target small-cluster use case. | Remove. Keep one placement control: `allowedNodes`. |
| `maxReplicasPerNode` | Exposes scheduler tuning beyond the simple product. | Remove. Deterministically spread across eligible nodes first, then cycle if replicas exceed nodes. |
| per-service readiness knobs | Every service currently exposes timeout and sample count. | Remove public options; use fixed systemd readiness policy. |
| autoscaling expert knobs | `sampleWindowSec`, cooldowns, and `maxStep` are exposed in `module.nix` and normalized in `Service`. | Remove from public schema; keep fixed constants internally. |
| public runtime timing knobs | Six timing/command options are exposed under `runtime`. | Remove public Nix options; keep tested internal constants. |
| deployment strategy knobs | `canaryNodes`, `maxUnavailable`, health timing, and `autoRollback`. | Remove public schema and CLI flags; use fixed sequential, always-rollback behavior. |
| `extraManagedUnits` | Escape hatch outside declared service units. | Remove. Every managed unit must derive from a declared service. |
| `enableDaemon` | An enabled Nix-Swarm node without its daemon is not a useful supported mode. | Remove; `enable = true` always enables `nix-swarmd`. |
| `onFailureUnits` and agent resource-limit knobs | Native NixOS can override `systemd.services.nix-swarmd` directly. | Remove Nix-Swarm-specific wrappers; document the standard NixOS override when needed. |
| installer/Disko starter | `examples/starter/flake.nix` still imports Disko, advertises `nixos-anywhere`, and exposes `node-c`; starter checks include Disko files. | Replace with one prepared-machine starter; delete Disko input/files and installer wording. |
| legacy `swarm` binary/symlink | `lib/nix_swarm.ex` calls it a compatibility symlink. | Remove in the next breaking release; keep only `nix-swarm`. |

### Keep as public options

- agent: `enable`, `package`, `nodeName`, `cookieFile`, `operatorUsers`, ports/firewall interface controls;
- nodes: `availability`, `deployHost`, `nixosConfiguration`;
- services: `replicas`, optional `unitTemplate`, `allowedNodes`, simplified `autoscaling`;
- no user-authored JSON/YAML/TOML artifacts.

---

## 3. Implementation sequence

### Task 1: Lock the simplified public contract with tests

**Objective:** Make the intended command and Nix option surface executable policy before deleting code.

**Files:**
- Modify: `test/nix_swarm_project_policy_test.exs`
- Modify: `test/nix_swarm_cli_test.exs`
- Modify: `test/nix_swarm_runtime_test.exs`
- Modify: `test/nix_swarm_security_test.exs`
- Modify: `docs/SWARM_PARITY.md`
- Modify: `AGENT.md`

**Steps:**

1. Add failing policy tests asserting the supported CLI contains only TUI/help/version, `cluster plan/apply/rollback/upgrade/credentials rotate/doctor/status`, `service logs`, and the new `service restart`.
2. Add failing tests asserting removed commands return a concise migration error rather than running compatibility code.
3. Add failing Nix/source policy tests rejecting public ingress, healthcheck, settings, preferred-node, label/constraint, max-per-node, readiness tuning, runtime tuning, canary, and parallel rollout options.
4. Update `AGENT.md` and `docs/SWARM_PARITY.md` with the narrowed contract and database/storage boundary.
5. Run focused tests and confirm they fail for the expected old surface.
6. Commit: `test: define simplified product surface`.

### Task 2: Collapse the CLI onto one deployment workflow

**Objective:** Remove overlapping cluster commands and scaffolding commands before adding new behavior.

**Files:**
- Modify: `lib/nix_swarm/cli.ex`
- Delete: `lib/nix_swarm/cluster/ensure.ex`
- Delete: `lib/nix_swarm/cluster/rebuild.ex`
- Delete: `lib/nix_swarm/service/templates.ex`
- Modify/Delete relevant tests: `test/nix_swarm_cli_test.exs`, `test/nix_swarm_service_templates_test.exs`, `test/nix_swarm_cluster_deploy_test.exs`

**Steps:**

1. Remove routing/help/options for `cluster init`, `cluster ensure`, `cluster rebuild`, `cluster members`, and `cluster upgrade prepare`.
2. Change credential routing to accept only `cluster credentials rotate --yes`; map it to the existing coordinated rotation implementation.
3. Remove `service create`, `service add`, and template `service list`.
4. Keep a clear migration error for one release: “use cluster apply”, “use cluster status”, or “copy examples/starter/services/example-web.nix”. Do not retain hidden execution aliases.
5. Remove now-unused strict options (`template`, `replicas`, `constraints`, `force`, canary and parallel rollout options as later tasks allow).
6. Run CLI tests.
7. Commit: `refactor: collapse operator commands`.

### Task 3: Make the TUI genuinely and only read-only

**Objective:** Remove unreachable mutation and rollout machinery from the 5,492-line TUI while preserving all read-only behavior.

**Files:**
- Modify: `lib/nix_swarm/tui.ex`
- Modify: `lib/nix_swarm/tui/state.ex`
- Modify: `lib/nix_swarm/config_files.ex`
- Delete: `lib/nix_swarm/update.ex`
- Modify: `test/nix_swarm_tui_test.exs`
- Modify: `test/nix_swarm_tui_internal_test.exs`
- Delete/modify: `test/nix_swarm_update_test.exs`

**Steps:**

1. Add characterization tests for dashboard, services, machines, logs, metrics, help, search, sorting, scrolling, and refresh.
2. Delete TUI fields and handlers for `update_fun`, `deploy_fun`, rollout confirmations, action confirmations, machine actions, operator actions, apply results, pending external edits, add/edit/delete prompts, and deployment jobs.
3. Remove `Deploy`, `Update`, and mutable `ConfigFiles` aliases from the TUI.
4. Reduce `ConfigFiles` to path discovery and read-only previews needed by the TUI; remove add/delete/rewrite helpers.
5. Delete `NixSwarm.Update` and its tests after references reach zero.
6. Verify TUI snapshots/characterization tests are unchanged for supported views.
7. Commit: `refactor: remove dead mutable TUI paths`.

### Task 4: Remove compatibility-only ingress and service metadata

**Objective:** Stop carrying features that explicitly do not orchestrate anything.

**Files:**
- Delete: `nix/nix-swarm/ingress.nix`
- Modify: `nix/nix-swarm/module.nix`
- Modify: `nix/nix-swarm/default.nix` or module import site
- Modify: `lib/nix_swarm/config.ex`
- Modify: `lib/nix_swarm/service.ex`
- Modify: `lib/nix_swarm/api.ex`
- Modify: `lib/nix_swarm/tui.ex`
- Modify: `lib/nix_swarm/ascii.ex`
- Modify relevant config/API/TUI/security tests

**Steps:**

1. Write failing tests that normalized service/runtime payloads no longer contain `ingress`, `healthcheck`, or `settings`.
2. Remove the ingress Nix module/import and rendered Erlang terms.
3. Remove service `healthcheck` and `settings` options, normalization, warnings, API fields, and TUI rendering.
4. Remove ingress visuals from `Ascii` rather than preserving fake routing semantics.
5. Add actionable Nix evaluation errors or migration documentation for removed options.
6. Run config, API, TUI, and Nix module tests.
7. Commit: `refactor: remove compatibility metadata`.

### Task 5: Simplify placement to deterministic spread plus allowlisting

**Objective:** Keep one understandable service placement control.

**Files:**
- Modify: `nix/nix-swarm/module.nix`
- Modify: `lib/nix_swarm/config.ex`
- Modify: `lib/nix_swarm/service.ex`
- Modify: `lib/nix_swarm/placement.ex`
- Modify: `lib/nix_swarm/tui.ex`
- Modify: `test/nix_swarm_placement_test.exs`
- Modify: `test/nix_swarm_runtime_test.exs`
- Modify examples under `examples/`

**Steps:**

1. Add tests proving replicas spread deterministically across active allowed nodes and cycle deterministically only when replicas exceed eligible nodes.
2. Add tests proving draining/maintenance nodes receive no assignments.
3. Remove node `labels`; remove service `constraints`, `preferredNodes`, and `maxReplicasPerNode`.
4. Keep `allowedNodes = [ ]` as the only per-service placement restriction.
5. Simplify placement diagnostics to unknown allowed node, no eligible live node, and unassigned replicas.
6. Add a migration note: replace constraints/preferences with explicit `allowedNodes` or leave empty for all active nodes.
7. Run placement, membership, reconciler, and distributed tests.
8. Commit: `refactor: simplify service placement`.

### Task 6: Fix deployment policy and remove rollout knobs

**Objective:** Implement one sequential, health-gated, always-rollback deployment policy.

**Files:**
- Modify: `nix/nix-swarm/module.nix`
- Modify: `flake.nix`
- Modify: `lib/nix_swarm/deploy.ex`
- Modify: `lib/nix_swarm/deploy/rollout.ex`
- Modify: `lib/nix_swarm/deploy/plan.ex`
- Modify: `lib/nix_swarm/cli.ex`
- Modify deploy/rollout/state-machine tests

**Steps:**

1. Add failing tests for fixed one-host batches, fixed 120-second/two-sample readiness, and mandatory rollback.
2. Remove public `deployment.canaryNodes`, `maxUnavailable`, `healthTimeoutSec`, `stableSamples`, and `autoRollback`.
3. Remove `--canary-hosts` and `--max-unavailable` from CLI parsing/help.
4. Keep targeted `--hosts` for manual maintenance.
5. Replace public values with named internal constants beside deployment behavior.
6. Simplify plan output so it explains the fixed sequential policy rather than reporting tunable width/canaries.
7. Run deploy, rollout, state-machine, and property tests.
8. Commit: `refactor: use one safe rollout policy`.

### Task 7: Remove runtime and agent expert knobs

**Objective:** Hide safe internal defaults and use standard NixOS overrides for exceptional systemd customization.

**Files:**
- Modify: `nix/nix-swarm/module.nix`
- Modify: `lib/nix_swarm/config.ex`
- Modify: `lib/nix_swarm/application.ex`
- Modify: `docs/CONFIG_REFERENCE.md`
- Modify runtime/config/module/security tests

**Steps:**

1. Add tests for fixed connect, reconcile, autoscale, failure-grace, recovery-stabilization, and command timeout constants.
2. Remove public `runtime.*` options while retaining the values internally.
3. Remove `enableDaemon`; `services.nix-swarm.enable = true` always enables the daemon.
4. Remove `extraManagedUnits` and prove polkit authorizes only units rendered from declared services.
5. Remove `onFailureUnits` and `resourceLimits`; document standard `systemd.services.nix-swarmd` overrides for advanced operators.
6. Keep systemd watchdog behavior and secure defaults.
7. Run runtime, watchdog, executor, and security tests.
8. Commit: `refactor: internalize runtime policy`.

### Task 8: Add memory-aware autoscaling with five public fields

**Objective:** Extend the existing CPU autoscaler with memory while reducing its public configuration surface.

**Files:**
- Modify: `nix/nix-swarm/module.nix`
- Modify: `lib/nix_swarm/service.ex`
- Modify: `lib/nix_swarm/config.ex`
- Modify: `lib/nix_swarm/executor.ex`
- Modify: `lib/nix_swarm/executor/systemd.ex`
- Modify: `lib/nix_swarm/executor/fake.ex`
- Modify: `lib/nix_swarm/autoscaler.ex`
- Modify: `lib/nix_swarm/operational_state.ex`
- Modify: `lib/nix_swarm/api.ex`
- Modify: `lib/nix_swarm/tui.ex`
- Modify autoscaler/executor/API/TUI tests

**Steps:**

1. Add executor tests for parsing `MemoryCurrent` and finite `MemoryMax`; represent an unlimited/missing `MemoryMax` as unavailable, never zero-percent usage.
2. Add pure autoscaler tests: scale up when CPU or memory is high; scale down only when both are low; hold when either metric is unavailable or between thresholds; clamp to min/max; change one replica per decision.
3. Add Nix/config tests for only `enable`, `minReplicas`, `maxReplicas`, `cpuTargetPercent`, and `memoryTargetPercent`.
4. Remove public sample-window/cooldown/max-step fields and move fixed values into `Autoscaler` constants.
5. Extend sampling and decision replication with bounded CPU and memory observations.
6. Emit a visible diagnostic when memory scaling is configured but `MemoryMax` is unlimited/unavailable. CPU scaling continues; memory does not silently use host memory.
7. Show the last autoscaling reason in status/TUI: CPU high, memory high, both low, cooldown, capacity, or metric unavailable.
8. Run autoscaler, executor, placement, reconciler, API, and TUI tests.
9. Commit: `feat: add opinionated memory autoscaling`.

### Task 9: Add one safe service restart command

**Objective:** Give operators a convenient maintenance restart without creating durable mutable service state.

**Files:**
- Create: `lib/nix_swarm/service_restart.ex`
- Modify: `lib/nix_swarm/cli.ex`
- Modify: `lib/nix_swarm/remote.ex` only if shared SSH execution primitives need a narrow helper
- Create: `test/nix_swarm_service_restart_test.exs`
- Modify: `test/nix_swarm_cli_test.exs`
- Modify: `test/nix_swarm_security_test.exs`

**Command:**

```bash
nix-swarm service restart --name api --source . --yes
```

Optional maintenance targeting:

```bash
nix-swarm service restart --name api --source . --hosts root@node-a --yes
```

**Steps:**

1. Add CLI tests requiring `--name`, `--yes`, clean evaluated `.nix` configuration, and a known declared service.
2. Build an evaluated restart plan from the deployment manifest/current placement; never accept arbitrary unit names from argv.
3. Resolve exact rendered units and their deploy hosts from trusted evaluated configuration and observed placement.
4. Restart one unit at a time through the existing noninteractive privileged SSH path.
5. After each restart, wait for strict systemd `running` readiness using the fixed timeout/samples.
6. Stop on first failure, report the affected host/unit, and leave normal systemd/reconciliation behavior intact. Do not implement restart rollback or another state record.
7. Print that start/stop are declarative (`replicas > 0` / `replicas = 0`).
8. Add security tests for unknown service names, shell metacharacters, forged units, unassigned slots, unavailable hosts, and confirmation omission.
9. Run focused CLI/security tests and a NixOS VM restart test.
10. Commit: `feat: add safe service restart`.

### Task 10: Replace the starter with one prepared-machine example

**Objective:** Make first use match the actual product boundary and remove installer/storage distractions.

**Files:**
- Modify: `examples/starter/flake.nix`
- Modify: `examples/starter/README.md`
- Modify: `examples/starter/cluster.nix`
- Modify/retain one machine under `examples/starter/machines/`
- Delete: `examples/starter/disko/`
- Delete: `examples/starter/machines/node-c/disko.nix`
- Delete obsolete hardened/installer variants that duplicate the one starter
- Modify: `flake.nix` starter syntax check
- Modify starter/project-policy tests

**Steps:**

1. Add policy tests proving the starter has no Disko input, disk device, `nixos-anywhere`, or installer workflow.
2. Make the starter one prepared NixOS node, one systemd binary service, and one optional commented second node.
3. Use only the simplified service/autoscaling schema.
4. Keep a link to the hardened module without making the starter a hardware/install matrix.
5. Delete Disko files and stale syntax checks.
6. Verify starter evaluation and operator smoke tests.
7. Commit: `refactor: simplify prepared-node starter`.

### Task 11: Remove legacy packaging names and update migration documentation

**Objective:** Present one product name, one operator command, and a clear breaking-change path.

**Files:**
- Modify: `lib/nix_swarm.ex`
- Modify: `nix/nix-swarm/packages.nix`
- Modify: `flake.nix`
- Modify: `docs/MIGRATING_TO_1.0.md`
- Modify: `README.md`, `docs/GETTING_STARTED.md`, `docs/OPERATIONS.md`, `docs/CONFIG_REFERENCE.md`, `docs/UPGRADES.md`, `docs/SECURITY.md`
- Modify package/operator smoke tests

**Steps:**

1. Remove the `swarm` compatibility binary/symlink and redundant package aliases where doing so does not break the normal `default`, `operator`, and `cluster` outputs.
2. Keep package outputs understandable: operator CLI and cluster runtime; preserve `default` as the normal installation output.
3. Document removed commands/options and exact replacements.
4. Document SQLite/PostgreSQL boundary: Nix-Swarm runs the process but does not migrate, replicate, back up, or fence its data.
5. Document autoscaling as suitable only when concurrent service instances are application-safe.
6. Update all command examples to the reduced surface.
7. Run documentation/policy/package smoke tests.
8. Commit: `docs: define simple v1 operator model`.

### Task 12: Full review and release verification

**Objective:** Prove simplification reduced surface area without weakening core safety.

**Files:**
- Modify as needed: release evidence catalog, scripts, and tests
- Do not add new user-facing configuration.

**Steps:**

1. Search for every removed command, option, module, ingress field, mutable TUI action, Disko reference, `nixos-anywhere`, and `swarm` compatibility binary.
2. Run `mix format --check-formatted`.
3. Run `mix clean && mix compile --warnings-as-errors`.
4. Run `mix hex.audit`.
5. Run focused autoscaling, service-restart, CLI, TUI, placement, deployment, and security tests.
6. Run `mix test --warnings-as-errors --cover`.
7. Run `nix flake check --no-build --no-write-lock-file`, then build the VM/operator/starter checks.
8. On a Docker-capable host, run the standard and hardened harnesses and prove reset after success and injected failure. Mark unavailable honestly if Docker is absent.
9. Run a clean-checkout release check at the exact revision.
10. Review `git diff --check`, the full diff, tracked files, generated artifacts, and secret-like additions.
11. Confirm source/test LOC decreased in the removed compatibility areas; do not treat test or safety code reduction as a goal by itself.
12. Commit any final documentation/test fixes, then request independent code review before push.

---

## 4. Acceptance criteria

- [ ] The supported command list is small and documented in one place.
- [ ] `cluster apply` is the only normal deploy/bootstrap path.
- [ ] Credential enrollment is implicit; only explicit rotation remains as a separate command.
- [ ] TUI code contains no file writes, editor launches, delete operations, deploy functions, rollout prompts, or mutable service controls.
- [ ] Start/stop remain Nix-declared replica changes; restart is the only imperative service lifecycle command.
- [ ] Restart accepts a service name only, derives exact units from evaluated Nix/placement, runs sequentially, requires confirmation, and verifies readiness.
- [ ] Service configuration contains only replicas, unit template, allowed nodes, and five autoscaling fields.
- [ ] Autoscaling responds to CPU and finite-`MemoryMax` memory utilization, changes one replica at a time, and never provisions machines or rewrites Nix.
- [ ] Placement uses deterministic spread, `allowedNodes`, and node availability only.
- [ ] Deployment is sequential and always rolls back attempted hosts after failure; no rollout strategy knobs remain.
- [ ] Ingress metadata, deprecated healthcheck strings, arbitrary settings, dead aliases, and installer/Disko starter content are gone.
- [ ] The query socket remains read-only and operators still never receive the BEAM cookie.
- [ ] Databases and storage are explicitly unmanaged.
- [ ] CLI and read-only TUI remain supported.
- [ ] Full Mix, security, Nix, VM, and available Docker checks pass from a clean checkout.

---

## 5. Risks and migration notes

### Breaking configuration cleanup

This is intentionally a breaking simplification. Fail with direct migration messages rather than silently ignoring old options. Update `docs/MIGRATING_TO_1.0.md` before release.

### Placement changes

Removing preferences, labels/constraints, and per-node caps can move replicas after upgrade. The migration guide must instruct users to translate hard requirements into `allowedNodes` and review `cluster plan` before applying.

### Memory scaling correctness

`MemoryCurrent` without a finite `MemoryMax` cannot produce a meaningful service percentage. Fail that metric closed and explain how to add `MemoryMax` in the service's NixOS systemd unit. Do not substitute host memory.

### Restart privilege boundary

Do not make the read-only query socket mutable. Use the existing explicit privileged SSH/operator deployment channel, strict evaluated service/unit allowlisting, confirmation, and bounded commands.

### Removing dead TUI code

Characterize supported views first. The goal is deletion, not a simultaneous redesign. Retain the TUI as a useful read-only dashboard.

### Release/testing complexity

Do not remove safety checks merely because they are complex. Product simplicity means fewer user concepts and options; robust internal validation remains valuable.
