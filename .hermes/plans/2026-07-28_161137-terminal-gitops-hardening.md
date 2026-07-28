# Terminal-First GitOps Hardening Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Keep Nix-Swarm’s CLI and read-only TUI while making the product fully code-defined and GitOps-capable: Git commits are the only deployable desired state, CI or an optional operator-side reconciler applies immutable reviewed plans, and every agent reports exactly which Git/Nix revision it is running.

**Architecture:** Preserve the leaderless agent runtime and restricted SSH-to-Unix-socket query boundary. Add a presentation-neutral operator context, immutable deployment-plan artifacts bound to a Git commit and Nix closures, code-defined rollout policy, agent source-revision reporting, GitOps status in the CLI/TUI, CI promotion workflows, and an optional hardened operator-side Git reconciler. Do not add mutable runtime desired state, a central scheduler, a database, arbitrary webhooks, or Git access to cluster agents.

**Tech Stack:** Elixir 1.20/OTP 28, Nix flakes, Git, systemd, existing restricted query protocol, ExUnit, NixOS VM checks, Docker integration harness, generic CI with a GitHub Actions reference workflow.

---

## 1. Definition of “fully GitOps” for Nix-Swarm

Nix-Swarm will satisfy these properties:

1. **Declarative:** Nodes, services, placement, capacity, rollout policy, ingress, runtime bounds, and deployment targets are Nix code.
2. **Versioned:** Production desired state is identified by a full Git commit and locked flake inputs.
3. **Immutable:** A reviewed plan is bound to the commit, tree, lock file, manifest, target closures, and rollout policy that produced it.
4. **Pull-request driven:** CI validates and publishes a plan before protected-branch promotion.
5. **Automatically reconcilable:** Merging/promoting a protected Git ref can trigger deployment through CI; an optional operator-side daemon may reconcile a configured ref for installations without CI runners.
6. **Auditable:** Agents report the deployed commit, configuration digest, closure/generation, and reconciliation status. Deployment receipts are machine-readable and attributable to commits.
7. **Drift visible:** CLI/TUI distinguish desired commit, deployed commit, runtime config digest, and current system generation.
8. **No out-of-band desired state:** CLI/TUI cannot create durable service state on agents. Runtime observations in DETS remain non-authoritative.
9. **Rollback is code-first:** Normal rollback is a Git revert or promotion of a previously reviewed commit. Native NixOS generation rollback remains an automatic safety response to a failed in-flight deployment and an emergency tool—not the long-term desired state.
10. **Secure delivery:** Agents do not clone Git, execute repository hooks, hold deployment keys, or expose a browser/API control plane. Delivery runs only on a trusted operator host or protected CI runner.

### What is not considered GitOps

- Applying an uncommitted or dirty checkout to production.
- Changing target hosts, canaries, batch width, or health policy only with CLI flags.
- Treating DETS, a TUI selection, a local JSON file, or a systemd generation as the desired-state database.
- Automatically executing code from untrusted pull requests with production credentials.
- Letting each agent independently pull and activate NixOS configurations.
- Using `nixos-rebuild` manually and then accepting the resulting host as authoritative.

---

## 2. Recommended operating modes

### Development mode

Local dirty-tree plans remain available for iteration, but are visibly marked `development` and cannot be applied to a strict production environment.

```bash
nix-swarm cluster plan --source .
```

### Strict GitOps mode

Production apply requires:

- a clean Git checkout;
- a full commit reachable from an allowed protected ref;
- a committed `flake.lock`;
- no submodule drift;
- a plan artifact generated from that exact commit;
- an exact plan fingerprint match at apply time;
- code-defined targets and rollout policy;
- successful validation and required approval.

```bash
nix-swarm gitops plan --source . --out .nix-swarm/plan.json
nix-swarm gitops apply --plan .nix-swarm/plan.json --yes
```

### CI-driven reconciliation (recommended first)

A merge to an environment branch/tag runs validation, creates the immutable plan, waits for protected-environment approval, applies that plan, verifies convergence, and stores a receipt.

### Optional operator-side reconciler (later)

`nix-swarm-gitopsd` runs on one dedicated operator host and polls one configured protected ref. It is only a deployment reconciler; it is not the cluster leader. Agent convergence remains independent of it.

---

## 3. Code-defined ownership matrix

| Concern | Authoritative definition |
| --- | --- |
| Nodes, labels, availability | Nix module |
| Services, replicas, constraints, unit templates | Nix module |
| Autoscaling bounds/policy | Nix module |
| Deployment targets/configurations | `lib.nixSwarm.deploymentManifest` |
| Canary order | Nix deployment policy |
| Batch width/max unavailable | Nix deployment policy |
| Health timeout/stable samples | Nix deployment policy |
| Automatic rollback policy | Nix deployment policy |
| Git repository/ref policy | GitOps operator Nix configuration or protected CI environment |
| Credentials | External secret provisioning/systemd credentials; only references are code-defined |
| Desired revision | Protected Git commit plus locked flake inputs |
| Runtime observations | DETS; never authoritative |
| Deployment receipt | Derived evidence keyed by commit/plan fingerprint; never desired state |

CLI flags may select source and output format, but strict mode must reject flags that override code-defined topology or rollout policy.

---

## 4. Combined improvement roadmap

### Priority 1: Make deployment plans immutable and Git-bound
### Priority 2: Move every production policy into Nix
### Priority 3: Report Git/closure drift end to end
### Priority 4: Establish CI promotion and receipts
### Priority 5: Extract shared operator behavior and split the TUI
### Priority 6: Version the restricted query protocol
### Priority 7: Improve status, explainability, diagnostics, and automation contracts
### Priority 8: Add optional continuous Git reconciliation
### Priority 9: Expand property, state-machine, compatibility, VM, and staging tests

---

## 5. Implementation tasks

### Task 1: Document GitOps invariants and strict-mode semantics

**Objective:** Make “fully GitOps” a testable contract rather than a marketing phrase.

**Files:**
- Create: `docs/GITOPS.md`
- Modify: `AGENT.md`
- Modify: `README.md`
- Modify: `docs/SWARM_PARITY.md`
- Modify: `docs/SECURITY.md`
- Test: `test/nix_swarm_project_policy_test.exs`

**Steps:**
1. Add failing policy tests asserting the runtime API has no desired-state mutators and the TUI remains read-only.
2. Document the ten GitOps properties above.
3. Document development, strict, CI, and optional reconciler modes.
4. Explicitly distinguish Git revert from emergency NixOS generation rollback.
5. State that agents never clone repositories or hold deploy credentials.
6. Run `nix develop --command mix test test/nix_swarm_project_policy_test.exs`.
7. Commit: `docs: define strict GitOps operating model`.

### Task 2: Add a Git source identity module

**Objective:** Deterministically identify the exact source proposed for deployment.

**Files:**
- Create: `lib/nix_swarm/git_source.ex`
- Create: `test/nix_swarm_git_source_test.exs`

**Data model:**

```elixir
%NixSwarm.GitSource{
  root: "/path/to/repo",
  commit: "40-hex-sha",
  tree: "40-hex-sha",
  branch: "main" | nil,
  dirty: false,
  shallow: false,
  lock_digest: "sha256-...",
  submodules_clean: true,
  remote: "sanitized-origin" | nil
}
```

**Steps:**
1. Write tests for clean, dirty, detached, shallow, missing Git, missing lock, untracked Nix file, changed lock, submodule drift, and paths containing spaces.
2. Use `git` argument arrays with bounded `System.cmd/3`; never invoke a shell.
3. Include tracked changes and relevant untracked source files in dirty detection.
4. Hash `flake.lock` and reject a missing lock in strict mode.
5. Sanitize remote URLs so embedded credentials are never returned or logged.
6. Add `strict?/1` validation with actionable errors.
7. Commit: `feat: identify immutable Git deployment sources`.

### Task 3: Define deployment plan artifact schema v1

**Objective:** Convert an ephemeral map into a stable, reviewable, machine-readable contract.

**Files:**
- Create: `lib/nix_swarm/deployment_plan.ex`
- Create: `test/nix_swarm_deployment_plan_test.exs`
- Modify: `lib/nix_swarm/json.ex`
- Modify: `lib/nix_swarm/deploy.ex`

**Required fields:**

```text
schemaVersion
createdAt
mode
toolVersion
source.commit
source.tree
source.lockDigest
source.dirty
manifestDigest
flakeInstallable
targets[].node
targets[].deployHost
targets[].nixosConfiguration
targets[].closure
canaries
batches
healthPolicy
autoRollback
validation
planFingerprint
```

**Steps:**
1. Write round-trip tests and reject unknown schema versions.
2. Canonically encode deterministic JSON before hashing.
3. Exclude timestamps and presentation text from `planFingerprint`.
4. Include closure paths, target mapping, manifest, source identity, and policy in the fingerprint.
5. Ensure no secret, SSH private-key path, cookie, or environment dump enters the artifact.
6. Add `write/2` using exclusive, mode-safe output and `read/1` with size limits.
7. Commit: `feat: add immutable deployment plan artifacts`.

### Task 4: Bind apply to the reviewed plan

**Objective:** Ensure the code applied is exactly the code reviewed.

**Files:**
- Modify: `lib/nix_swarm/deploy.ex`
- Modify: `lib/nix_swarm/cli.ex`
- Create: `test/nix_swarm_gitops_apply_test.exs`
- Modify: `test/nix_swarm_deploy_test.exs`
- Modify: `test/nix_swarm_cli_test.exs`

**Steps:**
1. Add `gitops plan --out PATH` and `gitops apply --plan PATH` parsing tests.
2. At apply, reload the plan, recompute Git identity, manifest, closures, policy, and fingerprint.
3. Refuse changed commit/tree/lock/manifest/target/closure/policy before any host mutation.
4. Refuse dirty or detached production sources unless policy explicitly allows a pinned detached commit.
5. Keep all closure builds and validation before mutation.
6. Preserve normal `cluster plan` for local development but label it non-strict.
7. Add explicit exit code for stale/mismatched plan.
8. Commit: `feat: apply only reviewed Git-bound plans`.

### Task 5: Move rollout overrides into Nix

**Objective:** Make production rollout behavior fully defined as code.

**Files:**
- Modify: `nix/nix-swarm/module.nix`
- Modify: `flake.nix`
- Modify: `docs/CONFIG_REFERENCE.md`
- Modify: examples under `examples/starter/` and `examples/config/`
- Modify: `lib/nix_swarm/deploy.ex`
- Create/modify relevant deployment and module tests

**Add deployment options:**

```nix
services.nix-swarm.deployment = {
  canaryNodes = [ "nix-swarm@node-a" ];
  maxUnavailable = 1;
  healthTimeoutSec = 120;
  stableSamples = 2;
  autoRollback = true;
  requireCleanGit = true;
  allowedRefs = [ "refs/heads/main" ];
  requireSignedCommits = false;
};
```

**Steps:**
1. Add Nix assertions for known canary nodes, valid widths, and bounded policy values.
2. Export policy through deployment manifest schema v2 while maintaining schema v1 read compatibility during migration.
3. In strict mode reject `--hosts`, `--canary-hosts`, `--max-unavailable`, and health-policy overrides.
4. Keep emergency overrides behind an explicitly named non-GitOps command requiring confirmation and audit output.
5. Update examples and tests.
6. Commit: `feat: define rollout policy entirely in Nix`.

### Task 6: Embed source revision in rendered agent configuration

**Objective:** Let every node prove which Git/Nix state it is running.

**Files:**
- Modify: `nix/nix-swarm/module.nix`
- Modify: `lib/nix_swarm/config.ex`
- Modify: `lib/nix_swarm/operational_state.ex`
- Modify: `lib/nix_swarm/api.ex`
- Modify: `test/nix_swarm_runtime_test.exs`
- Modify: integration tests

**Rendered metadata:**

```text
git_commit
git_tree
flake_lock_digest
manifest_digest
plan_fingerprint
nixos_configuration
system_closure
```

**Steps:**
1. Add typed config fields and validation.
2. Render metadata from the evaluated Nix configuration, not user-entered runtime flags.
3. Persist it as operational observation after reconciliation.
4. Include it in bounded overview/status responses.
5. Verify different live desired revisions produce a high-severity config mismatch and block destructive reconciliation.
6. Never read `.git` from agents; all metadata arrives in their immutable Nix closure/config.
7. Commit: `feat: report deployed Git and Nix identity from agents`.

### Task 7: Add GitOps sync and drift status

**Objective:** Make desired, deployed, and observed state differences obvious.

**Files:**
- Create: `lib/nix_swarm/gitops_status.ex`
- Create: `test/nix_swarm_gitops_status_test.exs`
- Modify: `lib/nix_swarm/api.ex`
- Modify: `lib/nix_swarm/cli.ex`
- Modify: `lib/nix_swarm/tui.ex` initially; later move to extracted view

**States:**

```text
:in_sync
:pending
:mixed_revision
:config_drift
:closure_drift
:unreachable
:unknown
```

**CLI:**

```bash
nix-swarm gitops status --source . --target nix-swarm@node-a
nix-swarm gitops status --json
```

**TUI header/panel:**

```text
GIT main@9af3e1c  │  3/3 IN SYNC  │  lock 1c2d…  │  plan 72ab…
```

**Steps:**
1. Write pure state-classification tests.
2. Compare local desired identity with each agent’s reported identity.
3. Keep last good cluster snapshot visible and mark stale/unreachable nodes.
4. Add actionable explanations for each drift class.
5. Commit: `feat: expose GitOps synchronization and drift`.

### Task 8: Create deployment receipts

**Objective:** Produce auditable evidence for each apply without creating a desired-state database.

**Files:**
- Create: `lib/nix_swarm/deployment_receipt.ex`
- Create: `test/nix_swarm_deployment_receipt_test.exs`
- Modify: `lib/nix_swarm/deploy.ex`
- Modify: `lib/nix_swarm/telemetry.ex`

**Receipt fields:** plan fingerprint, commit, target closures, start/end time, per-host result, health samples, rollback result, final observed revisions/digests, tool version, and overall outcome.

**Steps:**
1. Write deterministic schema and bounded serialization tests.
2. Generate receipts for success, pre-mutation failure, rollback success, rollback failure, and convergence timeout.
3. Write receipts to an operator-selected artifact directory with mode-safe atomic writes.
4. Emit a concise structured journal event, without secrets.
5. Do not use receipts as desired state or allow them to bypass Git verification.
6. Commit: `feat: emit auditable deployment receipts`.

### Task 9: Add protected CI plan and promotion workflows

**Objective:** Make PR review and protected-ref promotion the recommended deployment path.

**Files:**
- Create: `.github/workflows/gitops-plan.yml`
- Create: `.github/workflows/gitops-deploy.yml`
- Modify: `.github/workflows/ci.yml`
- Create: `docs/GITOPS_GITHUB_ACTIONS.md`

**PR workflow:**
1. Check out the exact PR merge commit without production credentials.
2. Run format, compile, Hex audit, coverage, flake checks, VM check, and strict plan generation against fixtures/non-secret targets.
3. Upload the plan summary and artifact.
4. Never execute untrusted PR code on a self-hosted production runner.

**Protected deployment workflow:**
1. Trigger only from protected branch/tag or manual promotion of a reviewed commit.
2. Use GitHub Environment approval and scoped secrets.
3. Check out the exact commit, regenerate/revalidate the plan, then apply.
4. Upload receipt and sanitized logs.
5. Set deployment status for the commit/environment.

Pin every action by commit SHA. Keep the implementation generic enough that GitLab CI or another runner can invoke the same CLI contracts.

**Commit:** `ci: add GitOps plan and protected promotion workflows`.

### Task 10: Make rollback Git-first

**Objective:** Ensure durable rollback changes desired state rather than leaving Git and hosts divergent.

**Files:**
- Modify: `lib/nix_swarm/cli.ex`
- Modify: `lib/nix_swarm/deploy.ex`
- Modify: `docs/OPERATIONS.md`
- Modify: `docs/GITOPS.md`
- Modify tests

**Behavior:**
- `gitops rollback --to COMMIT` creates/validates a plan for an ancestor commit and requires normal promotion/apply approval.
- `cluster rollback-generation` is renamed/documented as emergency compensation.
- Automatic rollback during a failed rollout remains generation-based, and the receipt reports that desired Git state was not promoted.

**Steps:**
1. Test ancestor validation and reject arbitrary/unreachable commits under strict policy.
2. Prefer Git revert/new commit in docs because it preserves an auditable forward history.
3. Show `out_of_sync_after_emergency_rollback` until Git desired state is reconciled.
4. Commit: `feat: make rollback follow Git desired state`.

### Task 11: Extract a shared operator context

**Objective:** Separate use cases from CLI/TUI presentation before further interface work.

**Files:**
- Create: `lib/nix_swarm/operator.ex`
- Create: `test/nix_swarm_operator_test.exs`
- Modify: `lib/nix_swarm/cli.ex`
- Modify: `lib/nix_swarm/tui.ex`

Expose normalized data-returning functions for overview, members, logs, doctor, GitOps status, plan, apply, receipts, and rollback. The context never prints, halts, or renders terminal widgets.

**Commit:** `refactor: extract terminal-independent operator context`.

### Task 12: Split the 5,591-line TUI without changing behavior

**Objective:** Improve maintainability while retaining the terminal-first product.

**Files:**
- Create modules under `lib/nix_swarm/tui/`:
  - `state.ex`
  - `data.ex`
  - `events.ex`
  - `jobs.ex`
  - `navigation.ex`
  - `format.ex`
  - `components/*.ex`
  - `views/{dashboard,topology,machines,services,logs,gitops,help}.ex`
- Split `test/nix_swarm_tui_test.exs` into focused test files

**Order:** pure formatters, components, views, navigation, refresh/jobs, then top-level runtime. Preserve characterization tests after each extraction.

Add GitOps view features:
- desired commit and protected ref;
- plan fingerprint;
- per-node deployed commit/closure;
- drift severity;
- last receipt/result;
- explanation of why a node is out of sync.

**Commit series:** one extraction per concern; do not make this a single large rewrite.

### Task 13: Version the query protocol and advertise capabilities

**Objective:** Support mixed operator/agent versions safely.

**Files:**
- Modify: `lib/nix_swarm/query_protocol.ex`
- Modify: `lib/nix_swarm/query_server.ex`
- Modify: `lib/nix_swarm/remote.ex`
- Modify query protocol/security tests

Add `protocol-version` and `capabilities` requests reporting release, operations, schemas, and bounds. Keep backward compatibility for the existing protocol and fail clearly on unsupported GitOps metadata.

**Commit:** `feat: negotiate restricted query capabilities`.

### Task 14: Harden CLI automation contracts

**Objective:** Make GitOps workflows reliable across CI systems.

**Files:**
- Modify: `lib/nix_swarm/cli.ex`
- Modify: `lib/nix_swarm/json.ex`
- Modify CLI tests and docs

**Requirements:**
- JSON for doctor, plan, GitOps status, apply result, and receipts.
- Exactly one JSON document on stdout in JSON mode.
- Progress and diagnostics on stderr.
- Stable `schemaVersion` fields.
- Documented exit codes, including invalid input, unreachable, unhealthy, stale plan, apply failure/rollback success, and rollback failure.
- No ANSI or shutdown noise in machine output.

**Commit:** `feat: stabilize CLI schemas and exit codes`.

### Task 15: Add placement and policy explainability

**Objective:** Make code-defined decisions auditable by humans.

**Files:**
- Create: `lib/nix_swarm/placement_explain.ex`
- Create tests
- Modify CLI/TUI operator views

Add explanations for eligibility, labels, allowed/preferred nodes, availability, per-node caps, deterministic score, and unowned slots. Add `config validate`, `config explain`, and `config diff` read-only commands.

**Commit:** `feat: explain declarative placement and config drift`.

### Task 16: Add sanitized diagnostics bundles

**Objective:** Simplify support without leaking credentials.

**Files:**
- Create: `lib/nix_swarm/diagnostics.ex`
- Create tests
- Modify CLI and docs

Collect source identity, plan metadata, versions, overview, membership, digests, placement issues, bounded logs, command timings, and systemd properties. Explicitly exclude cookies, private keys, secret directories, arbitrary environment variables, and raw process environments.

**Commit:** `feat: export sanitized GitOps diagnostics`.

### Task 17: Add optional `nix-swarm-gitopsd`

**Objective:** Provide continuous reconciliation for users without a CI deploy runner while keeping agents leaderless.

**Files:**
- Create: `lib/nix_swarm/gitops/reconciler.ex`
- Create: `lib/nix_swarm/gitops/repository.ex`
- Create: `lib/nix_swarm/gitops/state.ex`
- Create tests
- Create: `nix/nix-swarm/gitops-module.nix`
- Modify packages/flake/docs

**Strict design:**
- Runs only on a dedicated operator host.
- Fixed repository URL, ref, source subdirectory, interval, target environment, and signature policy are Nix-defined.
- Uses a private bare mirror plus detached clean worktree.
- Fetches without executing hooks.
- Deploys only commits reachable from the configured ref.
- Optionally verifies SSH/GPG or Sigstore policy using a fixed trusted-key set.
- Uses one global deployment lock.
- Regenerates and validates an immutable plan before apply.
- Stores only last observed/applied commit and receipt references as operational state.
- Exponential backoff; no rapid retry loops.
- Never responds to arbitrary webhook payloads.
- Never runs on cluster agents.

**Safety tests:** force-push, deleted ref, unsigned commit, invalid signature, dirty worktree, fetch failure, apply failure, rollback, daemon restart mid-operation, and two reconciler instances competing for the lock.

**Commit:** `feat: add optional protected-ref GitOps reconciler`.

### Task 18: Property, state-machine, compatibility, and system tests

**Objective:** Prove the GitOps invariants under failure and mixed versions.

**Files:**
- Add property tests, potentially with test-only `stream_data`
- Add deployment state-machine tests
- Add operator/agent compatibility fixtures
- Modify NixOS VM and Docker harness
- Modify `docs/TESTING.md`

**Required properties:**
- Same commit/lock/manifest yields same plan fingerprint.
- Changed relevant source always changes the fingerprint.
- Apply never mutates a host after a fingerprint mismatch.
- Unattempted hosts remain untouched after failure.
- Code-defined batch/canary policy cannot be silently overridden in strict mode.
- Agents with mixed commits/config digests block destructive reconciliation.
- GitOps controller failure does not affect agent convergence.
- Emergency generation rollback is reported as Git drift.
- Current/previous operator-agent combinations negotiate capabilities safely.

**System scenarios:** PR plan, protected promotion, successful rollout, failed canary, automatic rollback, Git revert rollout, operator restart, agent outage, force-push rejection, signature rejection, and recovery.

### Task 19: Release and repository hygiene

**Objective:** Establish a coherent versioned baseline before declaring GitOps stable.

**Files:** `VERSION`, `CHANGELOG.md`, release workflow, docs, examples.

**Steps:**
1. Decide whether the merged unreleased work is `0.5.0` or `1.0.0`.
2. Align version metadata and remove brittle historical test counts.
3. Resolve the local branch currently ahead of `origin/main`, the preserved stash, and untracked files intentionally.
4. Define deployment-plan and receipt schema compatibility policy.
5. Add a release gate for GitOps CI and staging rollback.
6. Commit: `release: establish GitOps compatibility baseline`.

---

## 6. Full verification gate

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
MIX_ENV=test nix develop --command mix run --no-start scripts/verify_cluster.exs
./scripts/docker-stack up
./scripts/docker-stack status
```

Additional GitOps acceptance tests:

1. Strict plan rejects a dirty tree, missing lock, submodule drift, or disallowed ref.
2. Plan artifact contains no credentials and has deterministic canonical JSON.
3. Editing any relevant Nix source after plan generation makes apply fail before mutation.
4. Code-defined targets, canaries, width, and health policy match the plan.
5. Every node reports the promoted Git commit, lock digest, manifest digest, plan fingerprint, and closure.
6. CLI and TUI show all nodes in sync after successful promotion.
7. A failed canary rolls back attempted hosts and produces a receipt.
8. Automatic generation rollback is shown as drift until Git is reconciled.
9. Reverting/promoting Git restores desired state through a new reviewed plan.
10. CI never gives production credentials to untrusted pull-request code.
11. Optional `gitopsd` does not affect running services when stopped or unavailable.
12. Agent packages contain no Git checkout, deploy key, or GitOps controller.
13. Query protocol remains bounded and read-only.
14. Full three-node failover works with the deployment controller offline.

---

## 7. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| “GitOps” becomes a central runtime controller | Controller handles deployment only; agents remain independently convergent. |
| Dirty local development becomes cumbersome | Keep explicit development plans, but prohibit production apply from them. |
| CI executes malicious PR code with secrets | Separate untrusted plan checks from protected deployment environments/runners. |
| Plan artifact is treated as authority | Recompute and verify against Git/Nix before apply; Git remains authority. |
| CLI flags bypass reviewed code | Reject rollout/topology overrides in strict mode. |
| Git rollback and Nix generation rollback diverge | Make Git rollback primary and display emergency generation rollback as drift. |
| Agents gain Git/deployment credentials | Keep Git and deploy credentials only on trusted operator/CI hosts. |
| Force-push changes promoted history | Require protected refs and optional signed commits; receipts retain applied commit IDs. |
| Optional reconciler creates duplicate deploys | Global operation lock plus plan/commit idempotency. |
| Git metadata leaks credentials | Sanitize remotes and never serialize environment/credential paths. |

---

## 8. Recommended release sequence

1. **Release A — Git identity and immutable plans:** Tasks 1–5.
2. **Release B — End-to-end drift visibility:** Tasks 6–10.
3. **Release C — Maintainability and operator UX:** Tasks 11–16.
4. **Release D — Optional continuous reconciliation:** Task 17 after CI-driven GitOps proves stable.
5. **Release E — GitOps stability declaration:** Tasks 18–19 plus real staging promotion/rollback evidence.

The key sequencing decision is to implement CI-driven GitOps before `nix-swarm-gitopsd`. That delivers full code-reviewed automation with less trusted resident infrastructure. The optional reconciler should be added only for environments that cannot use a protected deployment runner.
