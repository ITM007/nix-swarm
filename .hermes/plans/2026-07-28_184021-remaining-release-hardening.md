# Remaining Release Hardening Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Close the remaining automated quality, Docker/systemd, evidence, maintainability, and release-candidate gaps while defining machine preparation as an explicit user prerequisite outside Nix-Swarm.

**Architecture:** Nix-Swarm begins at an SSH-reachable, user-prepared NixOS machine and bootstraps the Nix-Swarm closure, missing credential, service, and cluster membership through the existing explicit `cluster apply` path. ExUnit/OTP state-machine tests model deployment safety; the Docker/systemd harness proves live onboarding, failure, upgrade, recovery, security, and cleanup behavior; a strict evidence collector orchestrates every release gate and rejects empty or partial runtime evidence. The CLI and TUI retain one read-only operator context while the monolithic TUI is decomposed without adding mutable controls or another desired-state model.

**Tech Stack:** Elixir/OTP 28, ExUnit, Nix/NixOS flakes and VM tests, Docker Compose with NixOS/systemd containers, Bash harnesses, Git.

---

## 1. Scope and non-goals

### Product boundary

Nix-Swarm assumes the operator has already prepared a compatible NixOS machine with:

- SSH host identity reviewed and pinned;
- public-key authentication;
- root SSH or passwordless noninteractive remote sudo;
- a supported architecture and sufficient disk for Nix closures;
- network reachability between trusted peers on the configured private interface;
- a user-authored `.nix` inventory entry identifying the node, deployment host, and NixOS configuration.

Nix-Swarm owns everything from preflight onward: closure build, missing-only credential enrollment, service activation, staged joining, existing-peer rollout, strict final convergence, and rollback of attempted hosts.

### Explicitly removed from release acceptance

The following are not Nix-Swarm release gates:

- disk partitioning or formatting;
- installing NixOS on bare metal;
- `nixos-anywhere` execution;
- Disko hardware-layout support or destructive installation evidence;
- generating hardware configuration;
- bootloader, firmware, RAID, encryption, Secure Boot, or machine-specific storage validation.

Existing provisioning examples may remain only if clearly labeled optional and unsupported. They must not be presented as the primary onboarding path or as a release-completeness requirement.

### Unchanged product constraints

- User-authored durable configuration remains `.nix` only; `flake.lock` is the normal generated exception.
- Git/Nix remain authoritative; no database, serialized deployment plan, JSON/YAML/TOML configuration, resident controller, or agent-side checkout.
- The TUI remains read-only.
- Mutation remains explicit through `cluster apply` or specifically named maintenance commands.
- No WebUI, Incus/LXC harness, secret store, overlay network, container orchestrator, or consensus system.

---

## 2. Workstream ordering

Implement in this order because later evidence depends on earlier harness behavior:

1. Correct the documented machine-preparation boundary.
2. Harden the release-evidence model and collector.
3. Add model/state-machine coverage for deployment invariants.
4. Make Docker profiles deterministic and scenario-capable.
5. Implement the live Docker failure matrix.
6. Decompose operator/TUI internals under characterization tests.
7. Add clean-checkout release orchestration and durable release-candidate evidence.
8. Run final review and classify any environment-dependent unavailable checks honestly.

Each task uses RED → GREEN → REFACTOR and ends in a coherent commit.

---

### Task 1: Replace the provisioning promise with a prepared-NixOS prerequisite

**Objective:** Make it unambiguous that users prepare NixOS machines and Nix-Swarm starts at preflight/bootstrap.

**Files:**
- Modify: `README.md`
- Modify: `AGENT.md`
- Modify: `docs/BOOTSTRAP.md`
- Modify: `docs/PROVISIONING.md`
- Modify: `docs/OPERATIONS.md`
- Modify: `docs/TESTING.md`
- Modify: `examples/starter/README.md`
- Modify: `.hermes/plans/2026-07-28_163547-code-first-bootstrap-upgrade-final.md`
- Test: `test/nix_swarm_project_policy_test.exs`

**Step 1: Write failing policy assertions**

Extend `test/nix_swarm_project_policy_test.exs` to assert that primary onboarding documentation:

- says the target is already running NixOS;
- names SSH, privilege, architecture, disk-space, private-network, and inventory prerequisites;
- identifies `cluster apply` as the first Nix-Swarm mutation;
- does not describe `nixos-anywhere` or Disko as a product/release requirement.

Do not ban incidental historical or optional references globally; test the canonical onboarding sections and release criteria so the policy is precise.

**Step 2: Verify RED**

Run:

```bash
nix develop --command mix test test/nix_swarm_project_policy_test.exs
```

Expected: FAIL because current docs and the old plan still make bare-metal provisioning part of release acceptance.

**Step 3: Amend documentation and the old roadmap**

- Rewrite onboarding around “prepare NixOS → declare node in `.nix` → plan → apply.”
- Replace bare-metal acceptance criteria with preflight acceptance against a prepared but Nix-Swarm-free NixOS target.
- Mark any retained Disko/nixos-anywhere sample as an optional user-owned example, not supported automation.
- Remove stale feature-completeness gaps and promises that say Nix-Swarm provisions the operating system.
- Preserve the existing hardened NixOS module and security guidance because those still govern Nix-Swarm installation.

**Step 4: Verify GREEN**

Run the focused policy test, then search canonical docs for contradictory claims:

```bash
nix develop --command mix test test/nix_swarm_project_policy_test.exs
rg -n 'turnkey|bare.?metal|nixos-anywhere|Disko' README.md AGENT.md docs examples/starter/README.md .hermes/plans
```

Expected: policy test passes; remaining references, if any, are explicitly optional/user-owned or historical.

**Step 5: Commit**

```bash
git add README.md AGENT.md docs examples/starter/README.md test/nix_swarm_project_policy_test.exs .hermes/plans/2026-07-28_163547-code-first-bootstrap-upgrade-final.md
git commit -m "docs: define prepared NixOS bootstrap boundary"
```

---

### Task 2: Make release evidence fail closed

**Objective:** Prevent empty Docker projects, unavailable required tools, dirty worktrees, or omitted gates from being reported as a passing release candidate.

**Files:**
- Modify: `lib/nix_swarm/release_evidence.ex`
- Modify: `scripts/collect_release_evidence.exs`
- Modify: `test/nix_swarm_release_evidence_test.exs`
- Create: `test/nix_swarm_release_evidence_script_test.exs`
- Modify: `docs/TESTING.md`

**Step 1: Add failing evidence-model tests**

Test these semantics:

- statuses are `:passed`, `:failed`, `:unavailable`, or `:skipped`;
- required `:unavailable` or `:skipped` gates make the overall result incomplete/nonzero;
- optional gates may be unavailable but cannot be rendered as passed;
- a Docker check with zero expected services fails as `empty_runtime`;
- report output includes command, exit status, duration, revision, clean/dirty state, and bounded redacted detail;
- redaction handles credential labels, cookie values, private-key blocks, bearer tokens, and long hexadecimal/base64-like secrets.

**Step 2: Add failing script-boundary tests through dependency injection**

Refactor the script entry point into a testable module such as `NixSwarm.ReleaseEvidence.Collector`, with injected command runner, clock, revision lookup, and filesystem writer. Tests must prove:

- required gates run in a deterministic declared order;
- a failing gate does not erase later diagnostics;
- output is written even when the collector exits nonzero;
- empty `docker compose ps` is rejected;
- the source checkout must be clean except for the configured evidence output under `_build/`;
- no command is built through shell interpolation.

**Step 3: Verify RED**

Run:

```bash
nix develop --command mix test \
  test/nix_swarm_release_evidence_test.exs \
  test/nix_swarm_release_evidence_script_test.exs
```

Expected: FAIL on missing aggregate status, empty-runtime validation, and injectable collector.

**Step 4: Implement minimal collector semantics**

Required gates should include:

```text
format
compile
hex_audit
tests_with_coverage
flake_check
nixos_vm
operator_smoke
starter_syntax
otp_integration
docker_standard_matrix
docker_hardened_matrix
docker_reset
clean_checkout
```

The collector should accept `--require-docker` for release runs. A developer-only mode may mark Docker unavailable, but the report must say `incomplete`, and the process must not return a release-success status.

Do not store credentials, Docker secrets, or full unbounded logs in the report.

**Step 5: Verify GREEN**

Run the focused tests and a dry/injected collector test. Confirm that an empty Compose project produces nonzero status and `empty_runtime`, not `passed`.

**Step 6: Commit**

```bash
git add lib/nix_swarm/release_evidence.ex scripts/collect_release_evidence.exs test/nix_swarm_release_evidence*_test.exs docs/TESTING.md
git commit -m "test: make release evidence fail closed"
```

---

### Task 3: Add a real deployment state-machine model

**Objective:** Model bootstrap and upgrade transitions so generated command sequences preserve safety invariants across failures.

**Files:**
- Modify: `mix.exs` only if adding a test-only property library is necessary
- Create: `test/support/deploy_state_machine.ex`
- Create: `test/nix_swarm_deploy_state_machine_test.exs`
- Modify: `test/nix_swarm_deploy_rollout_property_test.exs`
- Modify: `docs/TESTING.md`

**Step 1: Choose the smallest testing mechanism**

Prefer a deterministic ExUnit model with seeded generated command sequences. Add `stream_data` as `only: :test` only if it materially improves shrinking and reproducibility. Do not introduce runtime dependencies.

**Step 2: Write failing invariant tests**

Model states such as:

```text
prepared -> preflighted -> closures_built -> credentials_enrolled
-> bootstrap_activated -> bootstrap_ready -> existing_rolled
-> converged
```

and commands/failures including:

```text
classify_target
build_closure
enroll_missing_credential
activate_bootstrap
fail_bootstrap
roll_existing
fail_canary
fail_existing
convergence_timeout
kill_operator
rollback
mark_draining
mark_maintenance
remove_target
```

Assert after every generated transition:

- no mutation occurs before every selected closure is built;
- mismatched credentials never transition to enrollment or activation;
- bootstrap readiness precedes existing-peer expansion;
- batch width never exceeds `maxUnavailable`;
- rollback includes attempted activated hosts only;
- unattempted hosts remain unchanged;
- final success requires membership, one digest, placements, readiness, and reconciliation;
- killing the operator changes no agent desired/observed state;
- active removal is rejected until draining and maintenance transitions occur;
- blockers end the sequence before mutation.

**Step 3: Verify RED**

Run:

```bash
nix develop --command mix test test/nix_swarm_deploy_state_machine_test.exs --seed 0
```

Expected: FAIL because no state-machine model exists.

**Step 4: Implement the pure model and connect it to rollout/preflight outputs**

The model should call pure production planning/classification helpers where possible rather than duplicating their rules. Keep remote commands fake/injected; Docker proves the live path later.

**Step 5: Verify GREEN and repeatability**

Run multiple fixed seeds and preserve the failing seed in output:

```bash
for seed in 0 1 42 100 999; do
  nix develop --command mix test test/nix_swarm_deploy_state_machine_test.exs --seed "$seed" || exit 1
done
```

Expected: all seeds pass; failures, when induced during development, identify the minimal command sequence.

**Step 6: Commit**

```bash
git add mix.exs mix.lock test/support/deploy_state_machine.ex test/nix_swarm_deploy_state_machine_test.exs test/nix_swarm_deploy_rollout_property_test.exs docs/TESTING.md
git commit -m "test: model deployment failure transitions"
```

---

### Task 4: Turn the Docker harness into a deterministic scenario runner

**Objective:** Provide clean setup, scenario execution, evidence capture, and guaranteed teardown for standard and hardened profiles.

**Files:**
- Modify: `docker-compose.yml`
- Modify: `docker/nixos/flake.nix`
- Modify: `docker/nixos-systemd-image.nix`
- Modify: `scripts/docker-stack`
- Create: `scripts/docker-scenarios`
- Create: `test/nix_swarm_docker_harness_test.exs`
- Modify: `docs/TESTING.md`

**Step 1: Write failing harness-contract tests**

Without requiring Docker, test the script interface and static Compose contract:

- supported commands include `up`, `status`, `scenario`, `evidence`, `down`, and `reset`;
- `status` fails unless the expected services exist and are healthy;
- `reset` removes containers, networks, volumes, result links, and ignored development secrets created by the harness;
- scenarios have stable IDs matching the release catalog;
- standard and hardened profiles use isolated Compose project names;
- no production credentials or host-private data are embedded.

**Step 2: Verify RED**

Run:

```bash
nix develop --command mix test test/nix_swarm_docker_harness_test.exs
```

Expected: FAIL because current `status` accepts an empty project and no scenario runner exists.

**Step 3: Implement strict lifecycle commands**

- Add `status --assert-ready` that requires node-a, node-b, node-c, and operator with expected health/state.
- Add a `scenario <id>` delegation to `scripts/docker-scenarios`.
- Add traps so a failed scenario captures evidence before teardown.
- Make `reset` idempotent and verify no project containers/networks/volumes remain.
- Keep generated credentials under ignored `docker/nixos/secrets/`, redact values, and remove them on full reset.
- Ensure all waits are bounded and report the failed predicate.

**Step 4: Add scenario fixtures**

Use Compose profiles/overrides or Nix options to represent:

- prepared NixOS target with Nix-Swarm inactive/missing;
- low-disk target through a bounded test filesystem/quota fixture;
- wrong-architecture/no-builder preflight fixture without emulating another architecture;
- missing/matching/mismatched credentials;
- old-compatible and protocol-incompatible agent fixtures;
- workload readiness failure;
- private-interface and public-interface probes.

Do not add a container runtime to the product; Docker remains test infrastructure only.

**Step 5: Verify GREEN**

Run static tests first. When Docker is available, run:

```bash
./scripts/docker-stack reset
./scripts/docker-stack up
./scripts/docker-stack status --assert-ready
./scripts/docker-stack reset
```

Expected: ready assertion passes with four services; final reset proves no project resources remain.

**Step 6: Commit**

```bash
git add docker-compose.yml docker scripts/docker-stack scripts/docker-scenarios test/nix_swarm_docker_harness_test.exs docs/TESTING.md
git commit -m "test: add deterministic Docker scenario harness"
```

---

### Task 5: Implement the live bootstrap and credential Docker matrix

**Objective:** Prove onboarding of user-prepared NixOS targets through one explicit `cluster apply`.

**Files:**
- Modify: `scripts/docker-scenarios`
- Modify: `scripts/verify_cluster.exs`
- Modify: Docker Nix fixtures under `docker/nixos/`
- Create/modify: integration tests under `test/integration/`
- Modify: `docs/TESTING.md`

**Scenarios:**

1. Clean one-node cluster bootstrap.
2. Add one inactive/Nix-Swarm-free prepared NixOS target to two healthy peers.
3. Add multiple prepared targets.
4. Missing credential is enrolled and reaches readiness.
5. Matching credential is preserved.
6. Mismatched credential blocks before activation.
7. Unreachable target blocks before mutation.
8. Wrong architecture without builder blocks before mutation.
9. Low disk blocks before mutation.

**TDD steps for each scenario:**

1. Add the scenario assertion first and run it against the baseline to see the intended failure.
2. Add only the fixture/harness behavior needed for the scenario.
3. Run the scenario until green.
4. Capture plan, apply output, target generations, credential fingerprints only, membership, config digest, placements, readiness, and reconciliation.
5. Reset and assert no resources remain before proceeding.

**Acceptance details:**

- The prepared target starts as NixOS with SSH and deployment privilege, not as a blank machine.
- The only user-authored state change is `.nix` inventory/configuration.
- No credential value appears in logs, evidence, Nix store paths, argv, or environment.
- Blocked scenarios prove generation and service state were unchanged.

**Commit:**

```bash
git add scripts/docker-scenarios scripts/verify_cluster.exs docker test/integration docs/TESTING.md
git commit -m "test: cover live prepared-node bootstrap failures"
```

---

### Task 6: Implement the live rollout, upgrade, and recovery Docker matrix

**Objective:** Prove failure-safe staged rollout and mixed-version upgrade behavior.

**Files:**
- Modify: `scripts/docker-scenarios`
- Modify: `scripts/verify_cluster.exs`
- Modify: Docker Nix fixtures under `docker/nixos/`
- Create/modify: integration tests under `test/integration/`
- Modify: `docs/TESTING.md`

**Scenarios:**

1. New-node activation fails.
2. New node becomes ready, then an existing peer update fails.
3. Mixed config digest blocks destructive reconciliation.
4. Compatible minor rolling upgrade succeeds.
5. Protocol-incompatible upgrade rejects before the canary.
6. Canary health failure triggers rollback.
7. Final convergence times out and attempted hosts roll back.
8. Operator/deployment process dies while agents continue converging/serving.
9. Active node removal is rejected; draining → maintenance → removal succeeds.

**Required assertions:**

- closures are built before first mutation;
- attempted and unattempted hosts are recorded accurately;
- unattempted host generations remain unchanged;
- rollback occurs exactly once for attempted activated hosts;
- failed canary prevents later batches;
- compatible previous protocol remains queryable during rolling upgrade;
- incompatible protocol causes zero host mutation;
- killing the operator does not stop agents, workloads, or leaderless reconciliation;
- removal ordering is enforced from `.nix` availability state.

**Verification:**

Run every scenario independently from reset state, then run the whole matrix in one command. Require final `reset` even after a failed scenario.

**Commit:**

```bash
git add scripts/docker-scenarios scripts/verify_cluster.exs docker test/integration docs/TESTING.md
git commit -m "test: cover live rollout and upgrade failures"
```

---

### Task 7: Implement hardened runtime and closure-hygiene Docker checks

**Objective:** Prove the installed runtime has the intended security boundary and no development/source/secret leakage.

**Files:**
- Modify: `scripts/docker-scenarios`
- Modify: Docker hardened profile files under `docker/`
- Modify: `flake.nix` NixOS VM assertions where a VM is a stronger layer
- Modify: `test/nix_swarm_security_test.exs`
- Modify: `docs/SECURITY.md`
- Modify: `docs/TESTING.md`

**Scenarios/assertions:**

- public-key SSH succeeds; password authentication is disabled;
- root/passwordless deployment privilege matches the documented contract;
- BEAM/EPMD ports are reachable only on the configured trusted/private interface in the test topology;
- query socket outsider is rejected and operator-group user is accepted;
- daemon remains unprivileged and systemd sandbox/resource limits hold;
- no cookie or private key exists in argv, environment, public config, package source, or closure references;
- installed closure contains no project source checkout, Mix development toolchain, test files, Git metadata, or unexpected listening service;
- missing query helper and inactive daemon produce actionable doctor output;
- ANSI/control log injection remains terminal-safe.

**Verification:**

Run hardened Docker profile and NixOS VM checks. Do not claim Docker proves host-kernel firewall behavior; use it to prove generated policy and namespace-visible behavior, while Nix evaluation/VM checks validate module assertions.

**Commit:**

```bash
git add scripts/docker-scenarios docker flake.nix test/nix_swarm_security_test.exs docs/SECURITY.md docs/TESTING.md
git commit -m "test: verify hardened runtime and closure hygiene"
```

---

### Task 8: Decompose the read-only TUI under characterization tests

**Objective:** Complete the maintainability work without changing user-visible behavior or adding mutations.

**Files:**
- Create: `lib/nix_swarm/operator.ex`
- Create modules under `lib/nix_swarm/tui/`, likely:
  - `state.ex`
  - `data.ex`
  - `events.ex`
  - `jobs.ex`
  - `navigation.ex`
  - `format.ex`
  - `components.ex`
  - `views/dashboard.ex`
  - `views/nodes.ex`
  - `views/services.ex`
  - `views/logs.ex`
- Modify: `lib/nix_swarm/tui.ex`
- Modify: `lib/nix_swarm/operator_context.ex`
- Modify: `lib/nix_swarm/cli.ex`
- Split: `test/nix_swarm_tui_test.exs` into matching focused test modules
- Modify: `test/nix_swarm_project_policy_test.exs`

**Incremental extraction order:**

1. Freeze current rendering/navigation/job behavior with characterization tests.
2. Extract pure formatting helpers.
3. Extract state construction and state transitions.
4. Extract navigation/event mapping.
5. Extract data/query jobs with injected remote adapter.
6. Extract view renderers and components.
7. Introduce `NixSwarm.Operator` as the presentation-neutral read/query facade shared by CLI/TUI.
8. Reduce `NixSwarm.TUI` to lifecycle/mount/update orchestration.

**Invariants after every extraction:**

- `NixSwarm.TUI.read_only?/0` remains true;
- no start/stop/restart/mutable API is introduced;
- no desired state or plan is persisted;
- output and keybindings remain compatible;
- remote queries remain bounded through the restricted protocol;
- source/config paths still come from `NixSwarm.OperatorContext`.

**Verification:**

Run the focused extracted module tests after each step, then all TUI/CLI/project-policy tests. Commit in small coherent extractions rather than one large rewrite.

Suggested commits:

```text
refactor: extract TUI formatting and state
refactor: extract TUI data and event handling
refactor: extract read-only TUI views
refactor: share operator queries across CLI and TUI
```

---

### Task 9: Add clean-checkout release orchestration

**Objective:** Produce one reproducible command that proves the full release candidate from a clean checkout and always cleans Docker resources.

**Files:**
- Create: `scripts/release-check`
- Modify: `scripts/collect_release_evidence.exs`
- Modify: `scripts/docker-stack`
- Modify: `.gitignore`
- Create: `docs/RELEASE.md`
- Modify: `docs/TESTING.md`
- Test: `test/nix_swarm_release_evidence_script_test.exs`
- Test: `test/nix_swarm_project_policy_test.exs`

**Step 1: Write failing orchestration tests**

Test that the script:

- refuses a dirty checkout unless invoked in an isolated temporary worktree;
- creates an isolated Git worktree at the exact candidate revision;
- runs all required gates there;
- uses a unique Docker Compose project name;
- captures evidence before cleanup;
- runs reset in an `EXIT` trap;
- verifies no project containers, networks, volumes, result links, or generated credentials remain;
- exits nonzero for any required unavailable/failed/incomplete gate;
- writes only under `_build/release-evidence/` or a user-selected output directory.

**Step 2: Implement `scripts/release-check`**

Expected release command:

```bash
./scripts/release-check --require-docker --output _build/release-evidence
```

Required sequence:

1. Resolve candidate revision.
2. Create temporary detached worktree.
3. Confirm clean status.
4. Run `mix deps.get`, format, clean compile, `mix hex.audit`, and coverage tests.
5. Run full Nix flake check with build logs.
6. Build/run NixOS VM, operator smoke, and starter syntax checks.
7. Run OTP integration verification.
8. Run standard Docker matrix.
9. Reset and prove cleanup.
10. Run hardened Docker matrix.
11. Reset and prove cleanup.
12. Render summary plus per-gate bounded logs and checksums.
13. Remove temporary worktree.

**Step 3: Verify with injected commands, then live tools**

First run script tests without side effects. Then run the real release check on a Docker-capable host.

**Step 4: Commit**

```bash
git add scripts/release-check scripts/collect_release_evidence.exs scripts/docker-stack .gitignore docs/RELEASE.md docs/TESTING.md test/nix_swarm_release_evidence_script_test.exs test/nix_swarm_project_policy_test.exs
git commit -m "test: add clean-checkout release orchestration"
```

---

### Task 10: Final release-candidate review and documentation cleanup

**Objective:** Produce a reviewable release candidate without overstating unsupported machine provisioning.

**Files:**
- Modify: `VERSION` only if a version bump is approved
- Modify: `README.md`
- Modify: `docs/RELEASE.md`
- Modify: `docs/TESTING.md`
- Modify: `docs/OPERATIONS.md`
- Modify: `docs/UPGRADES.md`
- Modify: `.hermes/plans/2026-07-28_163547-code-first-bootstrap-upgrade-final.md`
- Create: release notes only in the repository’s established release-note format, if one exists

**Steps:**

1. Run `git diff --check` and inspect the full phase diff.
2. Run a pre-commit security/code-quality review.
3. Run `./scripts/release-check --require-docker` from the candidate revision.
4. Review evidence for redaction and ensure no credentials, cookies, private keys, host-private details, or Docker development secrets are tracked.
5. Confirm Docker reset evidence and clean `git status`.
6. Update acceptance criteria with actual pass/fail/unavailable states—not blanket checkmarks.
7. State the product promise narrowly: add Nix-Swarm to user-prepared NixOS machines through explicit `cluster apply`.
8. Keep version/tag/release publication as a separate operator-approved action after all required gates pass.

**Final commit:**

```bash
git add VERSION README.md docs .hermes/plans
git commit -m "docs: prepare Nix-Swarm release candidate"
```

Do not create or push a tag unless explicitly requested.

---

## 3. Final verification gate

Run from a clean candidate revision:

```bash
./scripts/release-check --require-docker --output _build/release-evidence
```

The underlying required commands are:

```bash
nix develop --command bash -c '
  mix deps.get &&
  mix format --check-formatted &&
  mix clean &&
  mix compile --warnings-as-errors &&
  mix hex.audit &&
  mix test --warnings-as-errors --cover
'

nix flake check --print-build-logs
nix build .#checks.x86_64-linux.nixos-vm --no-link --print-build-logs
nix build .#checks.x86_64-linux.operator-smoke --no-link --print-build-logs
nix build .#checks.x86_64-linux.starter-syntax --no-link --print-build-logs
MIX_ENV=test nix develop --command mix run --no-start scripts/verify_cluster.exs
./scripts/docker-stack reset
./scripts/docker-stack up
./scripts/docker-stack status --assert-ready
./scripts/docker-scenarios all
./scripts/docker-stack reset
```

Repeat the Docker matrix for the hardened profile.

### Required final evidence

- exact Git revision and clean-checkout proof;
- command, duration, exit status, and bounded redacted output for every gate;
- ExUnit count and coverage percentage;
- Nix derivation/check results;
- standard and hardened Docker scenario results;
- pre/post target generations for mutation/rollback scenarios;
- membership, digest, placement, readiness, and reconciliation proof;
- Docker cleanup proof showing no project resources remain;
- no tracked/generated secret material;
- explicit statement that target OS installation and hardware preparation are user responsibilities and were not tested.

---

## 4. Release acceptance criteria

A release candidate is acceptable when all of these pass:

- [ ] Canonical docs define a prepared NixOS machine as the starting point.
- [ ] No release criterion requires `nixos-anywhere`, Disko, partitioning, or OS installation.
- [ ] State-machine tests cover ordering, failure, rollback, process death, and removal invariants over generated sequences.
- [ ] Evidence collection rejects empty Docker projects and required unavailable gates.
- [ ] Standard Docker profile passes the complete bootstrap/credential/rollout/upgrade/recovery matrix.
- [ ] Hardened Docker profile passes SSH, privilege, query authorization, private-interface, systemd sandbox, and closure-hygiene checks.
- [ ] Mismatched credentials and incompatible protocols cause zero mutation.
- [ ] Failed canary/bootstrap/existing-peer/final-convergence scenarios modify only expected attempted hosts and roll them back exactly once.
- [ ] Killing the deployment process does not impair running agents or leaderless reconciliation.
- [ ] Active node removal is rejected until draining and maintenance are declared in Nix.
- [ ] CLI and TUI characterize all target states and remain read-only outside explicit apply/maintenance commands.
- [ ] TUI internals are decomposed into focused modules with no behavior regression.
- [ ] Full Mix, audit, coverage, Nix, VM, OTP integration, and Docker gates pass from an isolated clean checkout.
- [ ] Docker reset is proven after both success and injected failure.
- [ ] Evidence and Git contain no credential, cookie, key, token, secret path content, or private infrastructure details.
- [ ] Release notes accurately separate automated proof from user-owned machine preparation.

---

## 5. Risks and mitigations

### Docker/systemd fidelity

Docker cannot prove physical boot, host-kernel firewall enforcement, storage failure, or production networking. Mitigation: keep claims limited to NixOS/systemd container behavior, module evaluation, and the NixOS VM; make real staging an operator responsibility without making Nix-Swarm install the OS.

### Matrix runtime and flakiness

A full matrix may be slow and timing-sensitive. Mitigation: isolate scenarios, use bounded predicate waits instead of sleeps, print failing predicates, pin test releases/configurations, reset between scenarios, and support running one scenario by ID.

### Evidence leaks

Live logs may contain sensitive values. Mitigation: capture only bounded allowlisted diagnostics, redact before writing, test redaction adversarially, record credential fingerprints rather than contents, and keep generated secrets ignored and removed on reset.

### TUI refactor regression

A large extraction could alter behavior. Mitigation: characterization tests first, pure-module extraction in small commits, and no simultaneous UI redesign.

### Clean-checkout versus untracked test fixtures

Git flakes omit untracked files. Mitigation: commit every required fixture before the release run and execute from a detached temporary worktree at the exact candidate revision.

---

## 6. Deferred and explicit non-goals

## Implementation status at execution

- Prepared-NixOS boundary: implemented and policy-tested.
- Fail-closed evidence collector: implemented and tested; empty Docker output is
  a failed required runtime, not a pass.
- Deterministic deployment model: implemented; focused state-machine and seeded
  command-stream tests pass.
- Docker harness: implemented with standard/hardened profiles, stable scenario
  IDs, bounded status, evidence capture, failure injection, and reset cleanup.
  Live Docker execution remains unavailable until a Docker-capable host is used.
- TUI extraction: runtime and state construction were extracted into focused
  modules with characterization tests; the TUI remains read-only.
- Clean-checkout orchestration: implemented as `scripts/release-check`; it
  refuses dirty trees, uses a detached worktree, isolates Compose naming, and
  cleans Docker resources in an exit trap.
- Remote verification: formatting, warnings-as-errors compilation, full tests
  (`271 passed`, `67.48%` coverage), shell syntax, and `nix flake check`
  passed. Live Docker matrix evidence is not claimed because Docker is absent.

Do not add these while executing this plan:

- NixOS installation, Disko automation, or `nixos-anywhere` wrappers;
- machine hardware discovery or partitioning;
- additional storage/firmware profiles;
- Incus/LXC;
- WebUI;
- built-in GitOps controller;
- agent-side Git checkout;
- non-Nix user configuration or serialized plans;
- production secret management;
- mutable TUI controls;
- stateful workload failover guarantees;
- release publication/tagging without explicit approval.
