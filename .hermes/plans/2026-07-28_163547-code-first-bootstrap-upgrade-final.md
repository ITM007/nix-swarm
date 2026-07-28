# Code-First Bootstrap, Upgrade, and Operator Hardening Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Make Nix-Swarm a feature-complete, terminal-first, Nix-only orchestrator where adding an existing NixOS machine or upgrading the cluster is one explicit, safe, plan-driven `cluster apply` operation.

**Architecture:** Nix remains the only user-authored desired-state and deployment-policy format. `NixSwarm.Deploy` evaluates complete NixOS closures on a trusted deployment host, classifies each target, bootstraps new nodes before expanding existing peer configuration, performs bounded health-gated upgrades, and verifies final convergence. Cluster agents remain leaderless, never clone source repositories, and expose only the restricted read-only SSH/query boundary.

**Tech Stack:** Elixir 1.20/OTP 28, Nix/NixOS flakes, native `nixos-rebuild --target-host`, systemd, SSH, distributed Erlang on a trusted private network, ExUnit, NixOS VM tests, Docker systemd integration tests.

---

## 1. Final product principles

1. **Nix-only desired state:** Every user-authored configuration and durable deployment-policy file is `.nix`. Do not require JSON, YAML, TOML, Erlang terms, or serialized plan/receipt files.
2. **Standard Nix exception:** `flake.lock` is permitted as the standard Nix-generated lock file; users do not author a Nix-Swarm JSON schema.
3. **One mutation command:** Routine onboarding, configuration changes, service changes, and upgrades use `nix-swarm cluster apply --source .`.
4. **Explicit, not ambient:** Editing or saving a file never mutates production automatically. The explicit apply command or an external CI invocation starts deployment.
5. **Exact in-memory apply:** Apply evaluates, builds, presents, confirms, revalidates, and executes one in-memory plan. It never writes a second desired-state artifact.
6. **Code-defined policy:** Deployment targets, canaries, rollout width, health gates, rollback behavior, node availability, and service placement come from evaluated Nix.
7. **Native NixOS bootstrap:** Existing NixOS hosts are activated with `nixos-rebuild --target-host`; Nix-Swarm does not implement its own OS installer.
8. **Turnkey NixOS provisioning profile:** Nix-Swarm ships a maintained, minimal, hardened Disko/NixOS template that can be installed with `nixos-anywhere`; Disko and `nixos-anywhere` still own disk partitioning and OS installation.
9. **No central runtime controller:** The deployment process may stop after apply; agents continue membership, deterministic placement, and reconciliation independently.
10. **Safe partial failure:** Build all closures before mutation, deploy new-node bootstrap in the correct order, use canaries and bounded batches, and compensate failed attempted hosts with NixOS generation rollback.
11. **Git-friendly, not Git-dependent:** Git/CI may review and trigger Nix-Swarm, but repository policy, protected branches, and deployment approvals remain external concerns.
12. **Read-only operator UI:** CLI read commands and the TUI observe and explain state. Durable changes happen only through Nix deployment commands.

---

## 2. Correct bootstrap contract

A host is eligible for Nix-Swarm's **existing-NixOS bootstrap** when all of the following are true.

### Required before Nix-Swarm can act

- [ ] The target runs NixOS and has a working Nix installation/store.
- [ ] The target is reachable from the deployment host over SSH.
- [ ] The target authorizes the deployment host's SSH **public** key.
- [ ] The deployment host has verified and pinned the target's SSH host key in `known_hosts`.
- [ ] SSH authentication is noninteractive (`BatchMode=yes` succeeds).
- [ ] The deployment account is root, or passwordless noninteractive sudo is configured for remote activation; sudo must not require a TTY.
- [ ] The cluster flake contains a complete `nixosConfigurations.<name>` for the host.
- [ ] That configuration imports correct hardware/boot/filesystem configuration for the target.
- [ ] `system.stateVersion` is set to the target's original NixOS release, not blindly changed to the current release.
- [ ] The deployment/build host can build the target architecture, or a compatible remote builder is configured.
- [ ] The target has enough free disk space for the incoming closure and at least one rollback generation.
- [ ] Target names used in distributed Erlang are stable and mutually resolvable on the cluster network.
- [ ] Peer ports `4369/tcp` and `4370/tcp` are reachable only over a trusted encrypted interface such as WireGuard or Tailscale for multi-node clusters.
- [ ] System clocks and DNS/name resolution are operational enough for SSH, logs, and cluster diagnosis.
- [ ] The `.nix` configuration enables `services.nix-swarm`, declares the correct `nodeName`, peers, node metadata, and credential path.

### Credential clarification

The shared Nix-Swarm credential does **not** need to be pre-provisioned if Nix-Swarm is explicitly authorized to enroll it. One of these must be true:

1. **Preferred declarative route:** sops-nix, agenix, or systemd credentials installs the shared cookie outside `/nix/store`; or
2. **Built-in enrollment route:** a secure local cookie exists on the deployment host and `cluster apply` may idempotently install it on a missing target over privileged SSH.

A different existing remote cookie is an error. It must never be overwritten automatically. Coordinated credential rotation remains a separate confirmed maintenance operation.

### Not required before bootstrap

The target does **not** need:

- Nix-Swarm already installed;
- `nix-swarmd.service` already present;
- a Git checkout;
- the cluster source tree;
- Elixir/Mix tooling;
- an operator-side BEAM cookie;
- JSON/YAML/TOML manifests.

### Outside this contract

If the target does not yet run NixOS, use:

```bash
nixos-anywhere --flake .#node-c root@node-c
nix-swarm cluster apply --source .
```

Nix-Swarm must ship a tested starter profile for this path. The current
`examples/starter/machines/hardened-node.nix` is a useful hardening example, but
it is **not yet turnkey** because it imports a pre-existing
`hardware-configuration.nix`, the starter flake has no Disko input, and there is
no tested disk layout. The finalized implementation must close that gap.

### Turnkey `nixos-anywhere` profile contract

The repository must provide a complete example such as:

```text
examples/starter/
├── flake.nix
├── cluster.nix
├── profiles/
│   └── nix-swarm-node.nix
└── machines/
    └── node-c/
        ├── default.nix
        └── disko.nix
```

The generic `profiles/nix-swarm-node.nix` must define the reusable hardened
baseline. The machine directory must contain only hardware/site-specific values
and a destructive Disko layout selected deliberately by the operator.

The baseline must include:

- Nix-Swarm enabled with hardened mode and bounded resource limits;
- a stable node name supplied by the machine module;
- OpenSSH with public-key-only authentication, no password or keyboard-interactive login, no agent/X11 forwarding, and no unrestricted TCP forwarding;
- a declared deployment user or root key, with the private key kept outside the repository;
- explicit, minimal noninteractive deployment privilege when a non-root account is used;
- firewall default-deny behavior, SSH access, and BEAM ports scoped only to a declared private encrypted interface;
- no public BEAM exposure and no automatic firewall opening when no private interface is configured;
- systemd credential wiring that points outside `/nix/store` and causes a clear first-boot failure when the cookie has not yet been enrolled;
- Nix settings needed for flakes and remote closure deployment, without enabling untrusted users broadly;
- automatic security updates disabled by default so cluster changes remain explicit through `cluster apply`;
- journald persistence/retention suitable for diagnosis without unbounded disk use;
- time synchronization, deterministic hostname, locale/timezone defaults, and a conservative GC policy;
- no desktop environment, documentation payload, compiler toolchain, Git checkout, or unnecessary network daemon;
- a supported `system.stateVersion` that the user must consciously set and that upgrades never rewrite;
- bootloader and filesystem definitions supplied by Disko rather than a generated mutable hardware file.

The initial Disko examples should be intentionally narrow and clearly named:

1. `uefi-single-disk-ext4.nix` as the documented default;
2. optionally `uefi-single-disk-btrfs.nix` after the first profile is proven.

The operator must set the target disk device explicitly. Do not guess `/dev/sda`
or `/dev/nvme0n1`, and do not hide that `nixos-anywhere` will destroy the selected
disk. Disk encryption, RAID, Secure Boot/Lanzaboote, TPM enrollment, static network
bootstrapping, and cloud-specific storage are separate documented variants, not
unsafe defaults.

The supported workflow becomes:

```bash
# Review node-c/default.nix and node-c/disko.nix, especially the disk device,
# SSH public key, system architecture, stateVersion, and private interface.
nix flake check
nixos-anywhere --flake .#node-c root@node-c
nix-swarm cluster apply --source .
```

`nixos-anywhere` and Disko remain external tools; Nix-Swarm provides the correct
configuration and verification, but does not embed or reimplement their engines.

---

## 3. Target user experience

### Initial cluster

```bash
nix-swarm cluster init --source .
```

`cluster init` is a convenience alias for initial preflight, missing-credential enrollment, complete deployment, and convergence verification. It must not have a separate deployment implementation.

### Add an existing NixOS system

1. Add the machine and deployment metadata to `.nix`.
2. Add its complete `nixosConfigurations.<name>` output.
3. Provision SSH authorization and pin its host key.
4. Ensure private cluster networking/name resolution is available.
5. Run:

```bash
nix-swarm cluster apply --source .
```

The planner identifies the target as new and selects the bootstrap rollout automatically.

### Change services, placement, or host configuration

```bash
nix-swarm cluster apply --source .
```

### Prepare a Nix-Swarm upgrade

```bash
nix-swarm cluster upgrade prepare --source .
git diff -- flake.lock
```

This updates only the pinned `nix-swarm` input, evaluates and builds all closures, prints compatibility and rollout information, and mutates no host. The user reviews and commits `flake.lock` if desired.

### Apply an upgrade

```bash
nix-swarm cluster apply --source .
```

The normal apply path performs the canary/batched upgrade. Upgrades are ordinary Nix code changes, not a separate mutation protocol.

### Inspect

```bash
nix-swarm cluster doctor --source .
nix-swarm cluster status --source .
nix-swarm
```

---

## 4. Desired Nix structure

Avoid maintaining node metadata in two unrelated places. Define one Nix node inventory and derive the NixOS configurations, agent node map, peers, and deployment manifest from it where practical.

```nix
{
  nodes = {
    node-a = {
      system = "x86_64-linux";
      module = ./machines/node-a.nix;
      swarmName = "nix-swarm@node-a";
      deployHost = "root@node-a";
      availability = "active";
      labels = [ "apps" ];
    };

    node-c = {
      system = "aarch64-linux";
      module = ./machines/node-c.nix;
      swarmName = "nix-swarm@node-c";
      deployHost = "root@node-c";
      availability = "active";
      labels = [ "apps" "ssd" ];
    };
  };

  deployment = {
    canaryNodes = [ "nix-swarm@node-a" ];
    maxUnavailable = 1;
    healthTimeoutSec = 180;
    stableSamples = 3;
    autoRollback = true;
  };
}
```

The exact public helper API can evolve, but these invariants must hold:

- each deployable node maps to exactly one NixOS configuration;
- node/peer/manifest names cannot disagree;
- duplicate deploy hosts are rejected;
- canaries reference declared active nodes;
- deployment policy is evaluated from Nix;
- secrets are references, never Nix-store values.

---

## 5. Deployment state model

Every target is classified during preflight as one of:

```elixir
:new_nixos_host
:installed_inactive
:installed_unqueryable
:existing_in_sync
:existing_outdated
:draining
:maintenance
:unreachable
:incompatible
```

Classification uses bounded probes and must not treat absence of the query helper as a generic fatal error for a new host.

### Probe order

1. Validate evaluated Nix inventory and deployment policy.
2. Verify local build capability for each target system.
3. Verify SSH host-key and noninteractive authentication.
4. Verify the remote host is NixOS.
5. Verify privilege escalation if the deploy account is non-root.
6. Check free disk space against a conservative closure/rollback threshold.
7. Check shared credential state without reading or returning the credential.
8. Check whether `nix-swarmd.service` exists and is active.
9. If installed, invoke the restricted query helper and read version/config/closure state.
10. Produce classification plus explicit blockers and warnings.

### New-node deployment order

1. Evaluate the complete desired cluster.
2. Build every target closure before any host mutation.
3. Confirm the current existing cluster is healthy enough to expand.
4. Enroll the missing shared credential on new nodes, if using built-in enrollment.
5. Activate each new node's complete closure.
6. Wait for `nix-swarmd.service` readiness and restricted-query availability.
7. Update existing nodes in code-defined canary/batch order so they receive the new peer inventory.
8. Wait for all required peers to be live.
9. Require one configuration digest across live required nodes.
10. Require healthy placement, readiness checks, and owned systemd units.
11. Print a final summary; persist no plan file.

### Important ordering caveat

If the fully evaluated new-node closure already requires all peers during its startup health check, the bootstrap can deadlock before existing nodes know about the new peer. Implementation must explicitly support a transitional rollout state. The preferred approach is:

- activate the new node without requiring final-cluster membership for its bootstrap gate;
- update existing peers;
- enforce strict final-cluster health only after every batch is activated.

Do not weaken the final convergence gate.

---

## 6. Active test strategy

Use exactly two runtime test environments during this implementation:

```text
ExUnit/OTP peers       → application correctness
Docker/systemd cluster → fast multi-node runtime behavior
```

Nix evaluation and package/closure builds remain mandatory compile-time quality
gates, but they are not treated as a third live environment. Do not add Incus,
LXC, or another system-container harness during this plan.

### Layer 1: ExUnit and OTP peers

Run focused tests for every red/green/refactor cycle, then the full suite at the
end of each phase. This layer owns:

- inventory and policy validation;
- preflight classification with injected command adapters;
- credential state and enrollment behavior;
- deterministic plan/fingerprint behavior;
- bootstrap and rollout state machines;
- failure, rollback, timeout, and no-mutation-before-validation properties;
- query protocol capability compatibility;
- CLI/TUI presentation contracts;
- real distributed Erlang membership and convergence through `:peer`.

### Layer 2: Docker/systemd three-node cluster

Extend the existing `scripts/docker-stack` harness rather than creating a second
container backend. This layer owns:

- three independent NixOS userlands with systemd as PID 1;
- real packaged BEAM releases and restricted SSH/query traffic;
- new-node service absence, credential enrollment, activation, join, and rejoin;
- code-defined canary/batch behavior;
- mixed-version upgrade compatibility;
- failed canary compensation and final convergence;
- durable DETS behavior and bounded journal/query access;
- standard and hardened NixOS profiles.

Docker shares the host kernel and therefore does not prove firmware, bootloader,
initrd, Disko disk mutation, native firewall enforcement, or a true
`nixos-anywhere` installation. The Disko/hardened provisioning template will be
evaluated and built in Nix during this plan, and the documented
`nixos-anywhere --flake .#node-c` command will be manually validated on a
disposable real/virtual machine before a production release. That manual staging
exercise is deferred evidence, not a third automated harness in this phase.

### Per-phase gate

Every phase must finish with:

```bash
nix develop --command bash -c '
  mix format --check-formatted &&
  mix compile --warnings-as-errors &&
  mix test --warnings-as-errors
'
nix flake check --no-write-lock-file --print-build-logs
```

Phases that change runtime, deployment, credentials, membership, systemd, or
hardening must additionally run:

```bash
./scripts/docker-stack reset
./scripts/docker-stack up
./scripts/docker-stack query cluster-status
./scripts/docker-stack --profile hardened reset
./scripts/docker-stack --profile hardened up
./scripts/docker-stack --profile hardened query cluster-status
```

Always tear down test resources after collecting failure evidence.

---

## 7. Implementation phases

### Phase 0 — Baseline and scope lock

**Tasks:** establish the clean merged baseline; resolve version metadata and
working-tree/stash ambiguity; document the Nix-only, terminal-first product
contract; record baseline ExUnit/OTP and Docker evidence.

**Exit criteria:** both active test layers pass before feature work starts; no
credential or generated Docker secret is tracked; all decisions in Section 11
are accepted.

### Phase 1 — Nix inventory and hardened provisioning template

**Tasks:** 1, 2, and 12.

**Deliverable:** one code-defined node inventory and rollout policy plus a
minimal hardened Disko/NixOS starter that evaluates and builds for
`nixos-anywhere` without requiring `hardware-configuration.nix`.

**Exit criteria:** Nix assertions reject unsafe placeholders, duplicate or
inconsistent nodes, an unspecified disk, unscoped BEAM firewall exposure, and a
credential path in `/nix/store`; hardened Docker profile remains green.

### Phase 2 — Preflight and integrated credential enrollment

**Tasks:** 3 and 4.

**Deliverable:** bounded target classification and missing-only credential
enrollment with mismatches failing closed.

**Exit criteria:** ExUnit covers every target/credential state; Docker proves
missing, matching, and mismatched credential behavior without secret leakage.

**Phase 2 implementation evidence (2026-07-28):**

- Added typed `NixSwarm.Deploy.Target` identities and `NixSwarm.Deploy.Preflight` classification.
- Added bounded injected probe adapters and redacted probe result structures.
- Covered new NixOS, inactive, unqueryable, in-sync, outdated, draining, maintenance, blocking, and missing/mismatched credential states.
- Added `NixSwarm.Deploy.preflight/2`, which evaluates the deployment plan and probes targets without host mutation.
- Added `NixSwarm.Credentials.enroll_missing/1` as the explicit idempotent non-rotation enrollment operation.
- `cluster apply` now performs missing-only credential enrollment before deployment in the normal CLI path; injected deployment tests remain side-effect free.
- Remote verification passed: focused preflight tests (`13 passed`), full `mix test` (`225 passed`), formatting, and warnings-as-errors compilation.
- Docker evidence remains unavailable because Docker is not installed on the local or remote host; the required three-node acceptance scenario remains an environment-dependent release gate.

### Phase 3 — New-node apply workflow

**Tasks:** 5, 6, and 7.

**Deliverable:** one in-memory plan and one explicit `cluster apply` path that
bootstraps new NixOS targets, expands existing peers, and enforces strict final
convergence.

**Exit criteria:** the Docker harness starts with two active nodes and one
unprovisioned/disabled Nix-Swarm target, then proves enrollment, activation,
three-node membership, one config digest, healthy placement, and safe failure
before/after existing-peer updates.

**Phase 3 implementation evidence (2026-07-28):**

- Added pure `NixSwarm.Deploy.Rollout` planning with bootstrap-first stages, canary ordering, and bounded existing-node batches.
- Integrated rollout stages into `NixSwarm.Deploy.plan/1` and native `nixos-rebuild` execution.
- Added stage-aware attempted/unattempted host reporting and rollback context on failures.
- Added `NixSwarm.Deploy.Plan` with deterministic source/inventory/closure fingerprinting and an in-memory operator plan; no plan file is written.
- Extended `cluster plan` output with bootstrap, existing, maintenance, credential action, closure, rollout, health, and rollback sections.
- Remote verification passed: full `mix test` (`232 passed`), formatting, warnings-as-errors compilation, and `nix flake check --no-build --no-write-lock-file`.
- Docker evidence remains unavailable because Docker is not installed on the local or remote host; the required three-node acceptance scenario remains an environment-dependent release gate.

### Phase 4 — Reviewable, compatible upgrades

**Tasks:** 8, 9, and 10.

**Deliverable:** `cluster upgrade prepare`, ordinary apply-based upgrades,
protocol/capability negotiation, and closure/config/version drift status.

**Exit criteria:** Docker proves successful canary rollout, mixed compatible
versions, incompatible-version rejection before mutation, failed-canary
rollback, and unchanged unattempted nodes.

**Phase 4 implementation evidence (2026-07-28):**

- Added `NixSwarm.Upgrade.prepare/2`; it updates only the `nix-swarm` flake input, validates the resulting checkout, leaves a successful `flake.lock` change for review, and restores the exact prior lock on validation failure.
- Added the explicit `cluster upgrade prepare` CLI path; normal deployment remains `cluster apply`.
- Added query protocol version 2 plus bounded `protocol-version` and `capabilities` operations.
- Added API capability reporting and remote compatibility helpers.
- Added desired-versus-observed status with configuration digest, generation, release, drift fields, and synchronization state.
- Added `docs/UPGRADES.md` documenting prepare/review/apply semantics and fail-closed compatibility behavior.
- Remote verification passed: full `mix test` (`237 passed`), formatting, warnings-as-errors compilation, and `nix flake check --no-build --no-write-lock-file`.
- Docker evidence remains unavailable because Docker is not installed on the local or remote host; the mixed-version/canary acceptance matrix remains an environment-dependent release gate.

### Phase 5 — Operator usability and maintainability

**Tasks:** 11, 13, and 14.

**Deliverable:** actionable bootstrap/upgrade diagnosis, `.nix`-only machine
scaffolding, a shared operator context, and an incrementally decomposed read-only
TUI.

**Exit criteria:** no behavior regression in CLI/TUI characterization tests;
generated files are only `.nix`; Docker doctor/status output identifies all
supported failure classes.

### Phase 6 — Hardening and release evidence

**Task:** 15 plus final documentation/version cleanup.

**Deliverable:** property/state-machine coverage, automated Docker failure
matrix, reproducible evidence collection, and a release candidate.

**Exit criteria:** both active test layers pass from a clean checkout; all Docker
resources cleanly reset; Nix evaluation/build gates pass; a manual disposable
machine run of the documented `nixos-anywhere` command is recorded before the
feature is advertised as turnkey for bare metal.

### Phase execution rule

Implement only one phase at a time. Within a phase, follow TDD and commit small
coherent steps. Do not begin the next phase until the current phase's focused
tests, full ExUnit/OTP gate, applicable Docker scenarios, Nix evaluation/build,
and code review pass.

---

## 8. Implementation tasks

### Task 1: Establish bootstrap and upgrade contracts in documentation and policy tests

**Objective:** Turn the final product behavior and scope boundaries into executable policy.

**Files:**
- Create: `docs/BOOTSTRAP.md`
- Create: `docs/UPGRADES.md`
- Modify: `README.md`
- Modify: `AGENT.md`
- Modify: `docs/OPERATIONS.md`
- Modify: `docs/SECURITY.md`
- Modify: `test/nix_swarm_project_policy_test.exs`

**Steps:**
1. Write failing policy tests for Nix-only durable desired state, read-only TUI, no agent Git checkout, and no general OS provisioning code.
2. Document the prerequisite checklist above.
3. Document the credential exception and secure alternatives.
4. Document that `cluster apply` is the common mutation path.
5. Document the `nixos-anywhere`/Disko boundary.
6. Run the focused policy test and commit.

### Task 2: Define a single evaluated deployment inventory and policy contract

**Objective:** Eliminate duplicate/inconsistent node metadata and move all normal rollout policy into Nix.

**Files:**
- Modify: `nix/nix-swarm/module.nix`
- Modify: `flake.nix`
- Modify: `examples/starter/flake.nix`
- Modify: `examples/starter/cluster.nix`
- Modify: `examples/config/cluster/cluster.nix`
- Modify: `docs/CONFIG_REFERENCE.md`
- Modify: Nix module and deployment-manifest tests

**Steps:**
1. Add tests for unknown canaries, duplicate deploy hosts, missing NixOS configurations, invalid availability, and invalid rollout bounds.
2. Add/complete Nix-defined `canaryNodes`, `maxUnavailable`, health timeout, stable samples, and auto rollback.
3. Provide a Nix helper that derives peers and deployment manifest from one inventory where feasible.
4. Preserve manifest schema compatibility during migration.
5. Deprecate routine CLI topology/policy overrides; retain only explicitly named emergency behavior.
6. Run Nix evaluation/checks and commit.

### Task 3: Add typed target preflight and classification

**Objective:** Reliably distinguish bootstrap targets from upgrades and failures.

**Files:**
- Create: `lib/nix_swarm/deploy/preflight.ex`
- Create: `lib/nix_swarm/deploy/target.ex`
- Create: `test/nix_swarm_deploy_preflight_test.exs`
- Modify: `lib/nix_swarm/deploy.ex`

**Steps:**
1. Write table-driven tests for every classification state.
2. Implement bounded external commands using argument arrays, never shell interpolation.
3. Add SSH, NixOS, privilege, architecture, disk, credential fingerprint, service, query, and version probes.
4. Treat absent Nix-Swarm service/query helper as bootstrap state when NixOS preflight passes.
5. Treat a mismatched credential, unknown host key, incompatible architecture, or interactive sudo as a hard blocker.
6. Ensure logs/output redact sensitive paths and never read credential contents into result structures.
7. Run focused tests and commit.

### Task 4: Make credential enrollment an idempotent apply phase

**Objective:** Remove pre-provisioned credentials as a mandatory manual prerequisite while remaining fail-closed.

**Files:**
- Modify: `lib/nix_swarm/credentials.ex`
- Modify: `lib/nix_swarm/deploy.ex`
- Modify: `test/nix_swarm_credentials_test.exs`
- Modify: deployment integration tests

**Steps:**
1. Test missing, matching, mismatched, inaccessible, malformed, and declaratively provisioned credential states.
2. Add an internal enrollment operation used only for targets classified as new/missing credential.
3. Keep mismatches fail-closed unless the separate rotation command is explicitly used.
4. Ensure failed activation removes only temporary enrollment artifacts and never deletes an established credential.
5. Prefer declaratively provisioned credentials when the target reports one.
6. Run tests and commit.

### Task 5: Implement the two-stage new-node rollout

**Objective:** Bootstrap new agents before enforcing final expanded-cluster convergence.

**Files:**
- Create: `lib/nix_swarm/deploy/rollout.ex`
- Modify: `lib/nix_swarm/deploy.ex`
- Modify: `lib/nix_swarm/cluster/ensure.ex`
- Create: `test/nix_swarm_new_node_rollout_test.exs`
- Modify: `test/nix_swarm_deploy_test.exs`

**Steps:**
1. Write failing tests for one new node, multiple new nodes, mixed new/outdated nodes, failed bootstrap, failed existing-node update, and final convergence timeout.
2. Build all closures before enrollment or activation.
3. Bootstrap new nodes with a readiness/query gate that does not require final peer convergence.
4. Roll existing nodes in Nix-defined order.
5. Enforce strict final membership, digest, placement, readiness, and reconciliation gates.
6. Roll back only attempted activated hosts; report targets not yet attempted.
7. Make `Cluster.Ensure` delegate to the same rollout implementation or deprecate it as a compatibility alias.
8. Run focused and integration tests; commit.

### Task 6: Present one clear in-memory plan and verify it before mutation

**Objective:** Make onboarding and upgrades understandable without JSON plan files.

**Files:**
- Modify: `lib/nix_swarm/deploy.ex`
- Create: `lib/nix_swarm/deploy/plan.ex`
- Modify: `lib/nix_swarm/cli.ex`
- Modify: CLI/deploy tests

**Plan sections:**
- source and lock fingerprint;
- current cluster health;
- new bootstrap targets;
- existing upgrade targets;
- maintenance/excluded targets;
- blockers/warnings;
- credential enrollment actions without secret material;
- closures and architectures;
- rollout stages and health policy;
- rollback behavior.

**Steps:**
1. Write rendering and deterministic fingerprint tests.
2. Compute an internal fingerprint from relevant source, lock, inventory, policy, and built closure paths.
3. Recheck that fingerprint immediately before the first mutation.
4. Keep plan and apply in one process; do not serialize a plan artifact.
5. Make `--yes` skip only confirmation, never validation/build/fingerprint checks.
6. Run tests and commit.

### Task 7: Make `cluster apply` the common onboarding path

**Objective:** Reduce routine operator commands to one predictable workflow.

**Files:**
- Modify: `lib/nix_swarm/cli.ex`
- Modify: `lib/nix_swarm/cluster/ensure.ex`
- Modify: CLI tests and docs

**Steps:**
1. Add acceptance tests showing that normal apply handles new and existing targets.
2. Retain `cluster init` as a first-cluster convenience alias using the same planner/rollout.
3. Deprecate `cluster ensure` if it adds no distinct semantics.
4. Keep `cluster credentials --rotate-credentials` as an explicit maintenance operation.
5. Print actionable next steps on every blocker.
6. Run tests and commit.

### Task 8: Split upgrade preparation from deployment

**Objective:** Make upgrades reviewable Nix code changes rather than lock mutation plus immediate deployment.

**Files:**
- Modify: `lib/nix_swarm/upgrade.ex`
- Modify: `lib/nix_swarm/cli.ex`
- Modify: `test/nix_swarm_upgrade_test.exs`
- Modify: `test/nix_swarm_cli_test.exs`
- Modify: `docs/UPGRADES.md`

**Steps:**
1. Replace the current update-and-immediately-deploy behavior with `cluster upgrade prepare`.
2. Update only the `nix-swarm` flake input.
3. Evaluate/build all target closures and run compatibility checks without host mutation.
4. Print old/new release and revision, changed closures, and rollout policy.
5. On validation failure, restore the prior `flake.lock` exactly.
6. On success, leave `flake.lock` changed for review; deployment happens only through `cluster apply`.
7. Add a deprecation/error message for ambiguous legacy `cluster upgrade` behavior.
8. Run tests and commit.

### Task 9: Add mixed-version capability checks

**Objective:** Prove rolling upgrades are safe before mutating the canary.

**Files:**
- Modify: `lib/nix_swarm/query_protocol.ex`
- Modify: `lib/nix_swarm/query_server.ex`
- Modify: `lib/nix_swarm/remote.ex`
- Modify: `lib/nix_swarm/deploy/preflight.ex`
- Modify: query/security/compatibility tests

**Steps:**
1. Add bounded `protocol-version` and `capabilities` operations.
2. Advertise release, supported operation/schema versions, and response limits.
3. Support the immediately previous compatible agent protocol during rolling upgrades.
4. Refuse before mutation when the proposed operator/agent combination requires a coordinated outage.
5. Test old operator/new agent and new operator/old agent fixtures.
6. Run tests and commit.

### Task 10: Report desired-versus-observed closure and configuration state

**Objective:** Make successful onboarding and upgrades independently verifiable.

**Files:**
- Modify: `nix/nix-swarm/module.nix`
- Modify: `lib/nix_swarm/config.ex`
- Modify: `lib/nix_swarm/operational_state.ex`
- Modify: `lib/nix_swarm/api.ex`
- Modify: CLI/TUI status views and tests

**Report:** application release, configuration digest, runtime generation, NixOS configuration name, active system closure/generation, last successful reconcile, failed results, and query protocol version.

Do not require a Git commit and do not read `.git` on agents. Optional provenance may be injected by Nix evaluation, but closure/config identity is authoritative for runtime comparison.

### Task 11: Improve bootstrap/upgrade diagnostics

**Objective:** Make failures actionable without mutable control surfaces.

**Files:**
- Modify: `lib/nix_swarm/remote.ex`
- Modify: CLI/TUI doctor and status views
- Create focused diagnostics tests
- Modify: `docs/OPERATIONS.md`

Add explicit checks/messages for unknown host key, failed key auth, interactive sudo, wrong architecture, low disk, non-NixOS target, missing hardware config evaluation, missing/mismatched credential, absent service, failed readiness, private peer-port reachability, name-resolution mismatch, protocol incompatibility, and mixed config digest.

### Task 12: Ship a turnkey hardened `nixos-anywhere` profile

**Objective:** Make a fresh machine provisionable into a minimal, hardened Nix-Swarm-ready NixOS system with one reviewed flake target.

**Files:**
- Modify: `examples/starter/flake.nix`
- Create: `examples/starter/profiles/nix-swarm-node.nix`
- Create: `examples/starter/machines/node-c/default.nix`
- Create: `examples/starter/machines/node-c/disko.nix`
- Create: `examples/starter/disko/uefi-single-disk-ext4.nix`
- Modify: `examples/starter/README.md`
- Create: `docs/PROVISIONING.md`
- Modify: `flake.nix`
- Modify: NixOS VM and flake checks

**Steps:**
1. Add a pinned Disko flake input following the starter's `nixpkgs` input.
2. Write a failing flake/VM check that evaluates the `node-c` `nixosConfiguration`, Disko script, Nix-Swarm service, SSH policy, firewall scope, deployment privilege, and credential path.
3. Extract the current hardened example into a reusable minimal profile without importing a machine-specific `hardware-configuration.nix`.
4. Add a UEFI/GPT single-disk ext4 Disko function requiring an explicit `device` argument; evaluation must fail on an empty/default device.
5. Create `node-c/default.nix` containing explicit architecture, hostname, node name, disk selection, deployment public key placeholder, `stateVersion`, private interface, and inventory metadata.
6. Ensure the installed closure contains `nix-swarmd`, `nix-swarm-query`, SSH, time synchronization, bounded journald, and required Nix tooling—but no source checkout, compiler toolchain, desktop, or unrelated services.
7. Add assertions that password login is disabled, BEAM ports are not globally exposed, the cookie path is outside `/nix/store`, and a real SSH public key replaces the placeholder before production evaluation.
8. Document the destructive disk warning and the review checklist before `nixos-anywhere`.
9. Document first-boot credential behavior: declarative secret provisioning or subsequent missing-only enrollment by `cluster apply`.
10. Extend flake checks to evaluate the complete Disko script, NixOS closure, SSH policy, firewall scope, package set, and Nix-Swarm service contract without mutating a disk.
11. Document a manual disposable-machine acceptance procedure for `nixos-anywhere` and mark its evidence as required before a production release, not as a new automated environment in this phase.
12. Run `nix flake check --no-write-lock-file --print-build-logs` and the hardened Docker profile.
13. Commit: `feat: add hardened nixos-anywhere node template`.

**Phase 1 implementation evidence (2026-07-28):**

- Added the reusable `examples/starter/disko/uefi-single-disk-ext4.nix` layout and `node-c` machine wrapper.
- Added the hardened reusable NixOS profile and provisioning documentation.
- Evaluated a fully substituted `node-c` target with the local Nix-Swarm module override; hostname, hardened mode, node name, cookie path, and SSH policy all evaluated as expected.
- Built the fully substituted `node-c` NixOS system closure successfully without mutating a disk.
- `mix format --check-formatted`, warnings-as-errors compilation, `mix test` (`212 passed`), and `nix flake check --no-build --no-write-lock-file` passed remotely.
- Docker evidence was not available because Docker is unavailable on the local and remote development hosts; the Docker scenarios remain a later Phase 6 gate.

### Task 13: Add `.nix`-only machine scaffolding

**Objective:** Reduce boilerplate while keeping reviewed Nix as the only input.

**Files:**
- Create: `lib/nix_swarm/machine/templates.ex`
- Create: `lib/nix_swarm/machine/scaffold.ex`
- Create tests
- Modify: `lib/nix_swarm/cli.ex`
- Modify examples/docs

**Command:**

```bash
nix-swarm machine create --name node-c --deploy-host root@node-c
```

Generate only a machine directory containing `.nix` files based on the hardened
profile (`machines/node-c/default.nix` and an explicit Disko selection), then
print a Nix snippet/diff for inventory inclusion. Require the user to replace the
disk device, SSH public key, architecture, state version, and private interface
placeholders before evaluation succeeds. Do not automatically rewrite arbitrary
Nix source until a parser/formatter-preserving approach is proven. Never generate
JSON/YAML/TOML.

### Task 14: Refactor operator and TUI internals

**Objective:** Make future onboarding/status work maintainable without replacing the CLI/TUI.

**Files:**
- Create: `lib/nix_swarm/operator.ex`
- Split modules under `lib/nix_swarm/tui/`
- Split `test/nix_swarm_tui_test.exs`
- Modify: `lib/nix_swarm/cli.ex`

Extract a presentation-neutral operator context, then incrementally split the 5,591-line TUI into state, data, events, jobs, navigation, formatting, components, and views. Preserve the read-only invariant and characterization tests.

### Task 15: Add property, state-machine, and Docker failure tests

**Objective:** Prove bootstrap and upgrades under failure rather than only happy paths.

**Files:**
- Add property/state-machine tests under `test/`
- Modify Docker harness and Compose profiles
- Modify `scripts/verify_cluster.exs`
- Modify `docs/TESTING.md`

**Required scenarios:**
- clean one-node initial bootstrap;
- add one new node to a healthy two-node cluster;
- add multiple nodes;
- missing/matching/mismatched credential;
- unreachable target;
- wrong architecture without builder;
- low disk;
- failed new-node activation;
- new node ready but existing peer update fails;
- mixed config digest blocks destructive reconciliation;
- successful minor rolling upgrade;
- protocol-incompatible upgrade rejected before mutation;
- canary failure and rollback;
- final convergence timeout;
- deployment process dies while agents continue operating;
- removal only after draining/maintenance;
- private-interface firewall assertions.
- turnkey Disko profile evaluation with an explicit disk device;
- hardened template evaluation/build with no unsafe placeholders;
- public-key-only SSH policy and password-login rejection inside the hardened Docker profile;
- missing credential fails safely, followed by successful missing-only enrollment and service readiness;
- installed closure contains no source checkout, secret, development toolchain, or unexpected listening service.

---

## 9. Full verification gate

Run through the project development shell:

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
MIX_ENV=test nix develop --command mix run --no-start scripts/verify_cluster.exs
```

Then run the standard and hardened Docker/systemd workflows. Do not add Incus or
LXC. Before a production release that advertises fresh-machine provisioning,
run the documented `nixos-anywhere` command manually against a disposable
machine and retain the evidence.

### Release acceptance criteria

- [ ] The `node-c` Disko/NixOS target evaluates and builds in automated Nix checks; before production release, `nixos-anywhere --flake .#node-c root@node-c` is manually proven against a disposable machine after required values are supplied.
- [ ] The provisioned machine has public-key-only SSH, scoped private-interface cluster ports, minimal services/packages, correct deployment privilege, and no credential in `/nix/store`.
- [ ] The template refuses unsafe placeholders, an unspecified disk, an unscoped BEAM firewall, and a cookie path in `/nix/store`.
- [ ] A Docker NixOS/systemd target with no active Nix-Swarm service is added by changing only `.nix` desired state and running one explicit `cluster apply`; native installation remains a documented manual release check.
- [ ] Built-in enrollment installs a missing credential safely, while mismatches fail closed.
- [ ] Every closure is built before the first target mutation.
- [ ] New-node readiness is verified before existing nodes are expanded.
- [ ] Final success requires all required peers, one config digest, healthy placements, ready services, and successful reconciliation.
- [ ] A Nix-Swarm input update can be prepared and reviewed without deployment.
- [ ] The reviewed lock change deploys through ordinary `cluster apply` with canary and rollback behavior.
- [ ] A protocol-incompatible upgrade fails before mutation.
- [ ] TUI and CLI accurately show new, joining, in-sync, outdated, unreachable, and incompatible nodes.
- [ ] No user-authored non-Nix configuration or plan file is required.
- [ ] Agents contain no source checkout or deployment credential.
- [ ] Stopping the deployment process does not impair ongoing agent convergence.

---

## 10. Feature-completeness assessment

### Already substantially complete

The repository already has the core product:

- Nix-only desired state and generated runtime configuration;
- leaderless trusted-peer membership;
- deterministic placement and reconciliation;
- local operational observations separated from desired state;
- hardened unprivileged systemd service and exact-unit authorization;
- restricted read-only SSH/query protocol;
- complete NixOS closure evaluation and target-host deployment;
- build-before-mutation behavior;
- code-defined health policy, bounded batches, and automatic generation rollback;
- credential installation/rotation primitives;
- CLI, read-only TUI, diagnostics, logs, and cluster verification;
- broad unit, distributed, Nix evaluation/build, and Docker/systemd test layers.

### Gaps before calling onboarding/upgrades feature-complete

1. New nodes are not explicitly classified and orchestrated as a distinct bootstrap phase.
2. Credential installation is a separate workflow instead of an integrated missing-only apply phase.
3. `cluster upgrade` currently updates `flake.lock` and immediately deploys; preparation and application should be separated.
4. Mixed-version query capability negotiation is not a strong public contract.
5. Final status does not yet emphasize closure/version/config drift enough for upgrade verification.
6. Node inventory is duplicated in example flake/cluster structures and can drift.
7. The TUI and deployment modules are too large for low-risk long-term maintenance.
8. Real new-node and rolling-upgrade failure scenarios need stronger automated Docker evidence and a documented manual native provisioning check.
9. The repository has a hardened machine example but no complete Disko-backed, tested `nixos-anywhere` provisioning target.

### Optional features, not blockers

- Additional Disko variants beyond the supported minimal UEFI single-disk profile.
- A thin CLI wrapper around `nixos-anywhere`; the documented native command is sufficient initially.
- Cross-architecture remote builder discovery.
- Rich placement explanations and config diff commands.
- Stable machine-readable stdout for CI; this can be transient output and need not create files.
- External Git/CI examples.

### Explicit non-goals

Do not block feature completeness on:

- a WebUI;
- a built-in GitOps controller;
- agent-side Git pulls;
- JSON plan/receipt files;
- bare-metal partitioning logic;
- a secret store;
- container orchestration;
- overlay networking;
- a consensus database;
- mutable TUI service controls;
- stateful workload failover guarantees.

---

## 11. Decisions locked before implementation

The following choices are now defaults rather than open design questions:

1. **Test environments:** ExUnit/OTP peers and the existing Docker/systemd cluster only. No Incus/LXC harness now.
2. **Desired state:** `.nix` only; `flake.lock` is the standard Nix-generated exception.
3. **Mutation boundary:** one explicit `cluster apply`; no file watcher or built-in GitOps controller.
4. **Target authority:** evaluated Nix `deployHost` and `nixosConfiguration` are authoritative for normal apply. CLI host overrides are deprecated outside an explicitly labeled emergency path.
5. **Bootstrap transport:** SSH with pinned host keys and root or noninteractive passwordless sudo.
6. **Credential default:** declarative secret provisioning is preferred; built-in apply may install only a missing credential. A mismatch always fails closed.
7. **New-node ordering:** bootstrap/readiness first, existing-peer rollout second, strict full-cluster convergence last.
8. **Removal ordering:** active → draining → maintenance → remove from Nix inventory. Direct removal of a live active node is rejected or requires an explicit emergency path.
9. **Upgrade model:** prepare the pinned input/lock change, review it, then use ordinary apply. Support at least the immediately previous compatible query protocol during a rolling minor upgrade.
10. **Provisioning scope:** ship one supported `x86_64-linux`, UEFI/GPT, single-disk, ext4 Disko baseline first because it matches the active Docker harness. Additional architectures, storage layouts, encryption, Secure Boot, and cloud variants are deferred until a corresponding test target exists.
11. **Bare-metal evidence:** evaluate/build automatically now; manually prove `nixos-anywhere` on a disposable target before claiming turnkey production provisioning.
12. **No scope expansion:** no WebUI, container runtime, overlay network, secret store, database, consensus layer, or stateful failover promise.

These decisions are sufficient to begin. Any change to them is a product-scope
decision and should amend the plan before implementation rather than emerge
implicitly during coding.

---

## 12. Recommended release sequence

### Release A — Safe onboarding

Phases 0–3. Deliver an evaluated hardened `nixos-anywhere` template plus one-command apply for existing NixOS nodes, including preflight, missing credential enrollment, two-stage bootstrap, and strict final convergence in the Docker/systemd environment.

### Release B — Painless upgrades

Phase 4. Deliver reviewable upgrade preparation, ordinary apply rollout, compatibility negotiation, and closure/config status.

### Release C — Operational maturity

Phases 5–6. Deliver richer diagnosis, Nix-only scaffolding, internal maintainability, full Docker failure evidence, and the documented manual native provisioning acceptance run.

After Release B passes the Docker/systemd three-node add/upgrade/rollback matrix, Nix-Swarm can reasonably be described as **feature-complete for its intentionally narrow scope in the active automated environments**. Before advertising turnkey bare-metal provisioning as production-ready, complete the documented manual `nixos-anywhere` acceptance run. Release C is production-hardening and usability work rather than expansion into a larger orchestration platform.

---

## 13. Key product promise

> Provision a fresh machine from the shipped minimal hardened Disko/NixOS profile with `nixos-anywhere --flake .#node-c root@node-c`, then run one explicit `nix-swarm cluster apply`. For an existing NixOS system, declare it in Nix and begin at apply. Nix-Swarm builds the complete closure, enrolls a missing shared credential when authorized, installs itself if absent, joins the node in a safe staged rollout, and proves final convergence.

> Upgrade Nix-Swarm by updating its pinned Nix input, reviewing the resulting `flake.lock`, and running the same `cluster apply` workflow. No second configuration language, plan file, central controller, or agent-side source checkout is required.
