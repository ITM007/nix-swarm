# Nix-Swarm Verification Remediation Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Restore a fully passing Nix-Swarm test/verification pipeline and prove the packaged `nix-swarmd` runtime starts and remains healthy on the NixOS host.

**Architecture:** First establish one consistent executor contract at the public `NixSwarm.Executor` boundary: inputs are validated before any system command and all status APIs return `{:ok, status}` or `{:error, reason}`. Then make the reconciler consume that contract without crashing, reset cached runtime configuration between application lifecycles, and repair dependent API/TUI/deploy behavior and tests. Only after local fake-cluster verification is green should the NixOS module be deployed/enabled and checked as a real systemd service.

**Tech Stack:** Elixir 1.18 / OTP 27, ExUnit, Mix, Nix flakes, NixOS modules, systemd, distributed Erlang, `ex_ratatui`.

---

## Verified baseline and constraints

Run all development commands through the remote NixOS workspace because Mix is supplied by the flake dev shell:

```bash
cd /home/itm/hermes/workspace/projects/code/nix-swarm
nix develop -c mix <task>
```

Observed baseline:

- `nix flake check --no-build --no-write-lock-file` passes.
- `nix build .#cluster --no-link --print-build-logs` passes, but emits compilation warnings.
- `nix develop -c mix escript.build` passes, but emits compilation warnings.
- `nix develop -c mix format --check-formatted` fails.
- `nix develop -c mix test` reports **132 tests, 30 failures**.
- `nix develop -c mix run scripts/verify_cluster.exs` times out after `NixSwarm.Reconciler` calls status predicates with bare `:stopped`.
- `nix-swarmd.service` is currently not installed/loaded on `overlord`; prior journal records show a historical Type=notify startup timeout. Do not use the old journal output as proof of the currently built package’s behavior.

Do not change application behavior merely to match stale tests. For each discrepancy below, first decide and document the intended public contract, then update implementation and tests together.

## Root-cause map

1. **Executor contract mismatch:** `NixSwarm.Executor.Server.batch_unit_status/1` emits a map whose values are inconsistently nested (`{:ok, status}` for fresh results and bare `status` for cache hits). `NixSwarm.Reconciler` expects only the nested result shape. The reconciler predicates also lack safe clauses for bare statuses, so a fake cluster crashes instead of converging.
2. **Missing security boundary:** Tests require `NixSwarm.Executor.validate_unit_name/1`, but the public facade, `Executor.Server`, and `Executor.Systemd` do not validate systemd unit names before passing arguments to `systemctl` or `journalctl`.
3. **Test lifecycle configuration leak:** `NixSwarm.Config.current/0` caches configuration in `:persistent_term`; test setup changes application config but does not invalidate the persistent cache before starting the app. This explains tests seeing an empty/wrong service set after earlier tests.
4. **Dependent API failure:** `NixSwarm.API.fake_cluster_logs/1` interpolates `unit.status`. It must consume the normalized atom status, not `{:ok, status}`.
5. **TUI type error:** `NixSwarm.TUI.build_rollout_confirmation/2` passes a keyword list through `Map.get/2`. `rollout_targets/2` repeats this error, producing `BadMapError` instead of building rollout options.
6. **Deployment expectation drift:** Deploy planning now filters selected hosts against `deployHost` values from the cluster file, while tests still expect machine filename stems. SSH command tests use a literal-looking regex string that cannot match shell-escaped token output. The correct product policy must be selected and tested deliberately.
7. **Packaging/release hygiene:** `nix/nix-swarm/packages.nix` advertises `0.4.1` while `mix.exs` is `0.5.0`; compilation also reports an unused variable, unused match binding, outdented heredoc, and invalid `reraise` usage.

---

### Task 1: Establish the executor status/result contract

**Objective:** Define and test a single return shape for public executor calls and batched status lookup before repairing reconciliation.

**Files:**
- Modify: `lib/nix_swarm/executor.ex:8-53`
- Modify: `lib/nix_swarm/executor/server.ex:28-211`
- Modify: `lib/nix_swarm/executor/systemd.ex:6-106`
- Modify: `lib/nix_swarm/executor/fake.ex:4-89` only if needed to conform
- Create: `test/nix_swarm_executor_server_test.exs`
- Modify: `test/nix_swarm_executor_test.exs`

**Step 1: Write failing contract tests**

Add isolated tests that start `NixSwarm.Executor.Server` with a shell adapter seam (or extract a small injectable command runner) and assert:

```elixir
assert {:ok, %{ "a.service" => :running, "b.service" => :stopped}} =
         NixSwarm.Executor.batch_unit_status(["a.service", "b.service"])

# Run a second time inside the cache TTL; output must have the exact same shape.
assert {:ok, %{ "a.service" => :running, "b.service" => :stopped}} =
         NixSwarm.Executor.batch_unit_status(["a.service", "b.service"])
```

Also test that public `unit_status/1` consistently returns `{:ok, status}` and the public facade does not expose different shapes for fake, server, and fallback execution.

**Step 2: Verify RED**

Run:

```bash
nix develop -c mix test test/nix_swarm_executor_server_test.exs
```

Expected: failure showing the cached/fresh batch map shapes differ or the server cannot yet be tested through a command seam.

**Step 3: Implement the smallest consistent contract**

Choose exactly one representation:

- `NixSwarm.Executor.unit_status/1` -> `{:ok, status} | {:error, reason}`
- `NixSwarm.Executor.batch_unit_status/1` -> `{:ok, %{unit_name => status}} | {:error, reason}`

Normalize the server’s fresh and cached entries to bare status atoms internally and return one outer `{:ok, map}` only. Do not store nested tuples in `State.status_cache`. Update fallback code in `Executor.delegate/2` to preserve this public contract and replace the invalid `reraise __MODULE__` with valid error propagation (or avoid rescue by making fallback explicit).

**Step 4: Verify GREEN**

Run:

```bash
nix develop -c mix test test/nix_swarm_executor_server_test.exs test/nix_swarm_executor_test.exs
```

Expected: all executor contract tests pass.

**Step 5: Commit**

```bash
git add lib/nix_swarm/executor.ex lib/nix_swarm/executor/server.ex lib/nix_swarm/executor/systemd.ex lib/nix_swarm/executor/fake.ex test/nix_swarm_executor_server_test.exs test/nix_swarm_executor_test.exs
git commit -m "fix: normalize executor status results"
```

---

### Task 2: Implement unit-name validation at every command boundary

**Objective:** Prevent option injection, traversal, shell metacharacters, and malformed unit names from reaching systemd/journal commands.

**Files:**
- Modify: `lib/nix_swarm/executor.ex`
- Modify: `lib/nix_swarm/executor/server.ex`
- Modify: `lib/nix_swarm/executor/systemd.ex`
- Modify: `test/nix_swarm_executor_test.exs`
- Modify: `test/integration/cluster_api_integration_test.exs`

**Step 1: Write the failing validation tests first**

Retain existing accepted/rejected cases and add boundary cases for:

```elixir
assert :ok = Executor.validate_unit_name("gitea@0.service")
assert :ok = Executor.validate_unit_name("foo-bar_1.socket")
assert {:error, :invalid_unit_name} = Executor.validate_unit_name("--property=Foo")
assert {:error, :invalid_unit_name} = Executor.validate_unit_name("a/b.service")
assert {:error, :invalid_unit_name} = Executor.validate_unit_name("unit\n.service")
```

For every unit-taking public operation, assert invalid input returns its documented safe result without invoking the command runner:

- start/stop/restart/logs -> `{:error, :invalid_unit_name}`
- status -> `{:ok, :unknown}`
- metrics -> zero metrics

**Step 2: Verify RED**

```bash
nix develop -c mix test test/nix_swarm_executor_test.exs test/integration/cluster_api_integration_test.exs
```

Expected: current missing `validate_unit_name/1` and command-reaching failures reproduce.

**Step 3: Implement minimally**

Add public `validate_unit_name/1` in `NixSwarm.Executor`. Permit only non-empty, bounded-length systemd-style names made of a conservative allowlist (letters, digits, `.`, `_`, `-`, `@`) and require a unit type suffix such as `.service`, `.socket`, `.target`, `.timer`, `.path`, `.mount`, `.slice`, or `.scope`. Reject leading `-`, paths, whitespace, empty values, non-binaries, and overlong names.

Validate at the public facade before dispatch. Also defend in `Executor.Server` and `Executor.Systemd` if they can be called directly. Preserve the safe status/metrics semantics rather than raising.

**Step 4: Verify GREEN**

```bash
nix develop -c mix test test/nix_swarm_executor_test.exs test/integration/cluster_api_integration_test.exs
```

Expected: no invalid name reaches `systemctl`, and all listed tests pass.

**Step 5: Commit**

```bash
git add lib/nix_swarm/executor.ex lib/nix_swarm/executor/server.ex lib/nix_swarm/executor/systemd.ex test/nix_swarm_executor_test.exs test/integration/cluster_api_integration_test.exs
git commit -m "fix: validate systemd unit names before execution"
```

---

### Task 3: Make reconciliation total over normalized statuses

**Objective:** Make fake three-node convergence deterministic and prevent a status shape from crashing reconciliation.

**Files:**
- Modify: `lib/nix_swarm/reconciler.ex:164-212,385-389`
- Modify: `test/nix_swarm_reconciler_test.exs`
- Modify: `test/integration/three_node_cluster_test.exs`
- Modify: `scripts/verify_cluster.exs`

**Step 1: Write failing regression tests**

Add direct reconciliation tests covering:

- desired unit with `:stopped` -> one start operation;
- unowned unit with `:stopped` -> no stop operation;
- `:running`, `:starting`, `:restarting`, `:stopping`, `:failed`, `:unknown` -> documented action choice;
- an unexpected executor result -> no GenServer/task crash and a safe result entry;
- fake cluster initially contains stopped files and still converges.

Use `NixSwarm.Executor.Fake` and an explicit config; do not mock the reconciler’s decision logic.

**Step 2: Verify RED**

```bash
nix develop -c mix test test/nix_swarm_reconciler_test.exs test/integration/three_node_cluster_test.exs
nix develop -c mix run scripts/verify_cluster.exs
```

Expected: current `FunctionClauseError` on `:stopped` and verification timeout reproduce.

**Step 3: Implement the minimal reconciliation correction**

Consume the normalized `{:ok, %{unit => status}}` batch result from Task 1. Make predicate functions total over allowed status atoms and default unknown/unrecognized values to safe behavior. Do not add an ad hoc tuple-unwrapping workaround unless the executor contract explicitly requires it.

Ensure the Task stream preserves a structured result for every unit, including an executor failure, rather than dropping failed task entries. Keep the existing idempotent placement and zero-replica behavior unchanged.

**Step 4: Verify GREEN**

```bash
nix develop -c mix test test/nix_swarm_reconciler_test.exs test/integration/three_node_cluster_test.exs
nix develop -c mix run scripts/verify_cluster.exs
```

Expected: reconciler tests, full three-node integration test, restart/log/failover script, and zero-replica stop test pass.

**Step 5: Commit**

```bash
git add lib/nix_swarm/reconciler.ex test/nix_swarm_reconciler_test.exs test/integration/three_node_cluster_test.exs scripts/verify_cluster.exs
git commit -m "fix: converge stopped fake units during reconciliation"
```

---

### Task 4: Fix configuration cache lifecycle and dependent fake logs

**Objective:** Ensure each test/application lifecycle reads the current `:cluster_config`, and ensure API fake logs stringify only normalized statuses.

**Files:**
- Modify: `lib/nix_swarm/config.ex:15-29`
- Modify: `lib/nix_swarm/application.ex:7-27`
- Modify: `lib/nix_swarm/api.ex:454-470`
- Modify: `test/nix_swarm_reconciler_test.exs`
- Modify: `test/integration/cluster_api_integration_test.exs`
- Add or modify: `test/nix_swarm_config_test.exs`

**Step 1: Write failing lifecycle tests**

Create an ExUnit test that:

1. sets one `:cluster_config`, calls `Config.current/0`, and verifies service A;
2. stops the app or explicitly sets a new config for a new lifecycle;
3. verifies `Config.current/0` returns service B, not stale service A.

Add an API test that starts the fake cluster, calls `cluster_logs/2`, and asserts it returns a binary containing normalized `running`/`stopped` text without `Protocol.UndefinedError`.

**Step 2: Verify RED**

```bash
nix develop -c mix test test/nix_swarm_config_test.exs test/nix_swarm_reconciler_test.exs test/integration/cluster_api_integration_test.exs
```

Expected: stale config service assertions and/or fake log stringification fail on the existing implementation.

**Step 3: Implement minimally**

Pick a clear ownership model:

- In application/test lifecycle code, call `NixSwarm.Config.invalidate_cache/0` before a newly configured runtime starts; and/or
- Make a configuration setter/reset helper with tests, rather than silently bypassing persistent-term caching on every call.

Use the same lifecycle mechanism in `TestCluster` setup if needed. Update `fake_cluster_logs/1` to rely on the Task 1 public status contract and convert only atom statuses with `to_string/1`.

**Step 4: Verify GREEN**

```bash
nix develop -c mix test test/nix_swarm_config_test.exs test/nix_swarm_reconciler_test.exs test/integration/cluster_api_integration_test.exs
```

Expected: local status reports both configured services, health checks run, service mode operations find configured services, and fake cluster log refresh works.

**Step 5: Commit**

```bash
git add lib/nix_swarm/config.ex lib/nix_swarm/application.ex lib/nix_swarm/api.ex test/nix_swarm_config_test.exs test/nix_swarm_reconciler_test.exs test/integration/cluster_api_integration_test.exs test/support/test_cluster.ex
git commit -m "fix: reset runtime config between cluster lifecycles"
```

---

### Task 5: Repair rollout option handling in the TUI

**Objective:** Make rollout confirmation work for cluster and selected-machine scopes without map/keyword-list type errors.

**Files:**
- Modify: `lib/nix_swarm/tui.ex:1152-1244`
- Modify: `test/nix_swarm_tui_test.exs` near failing tests at lines 450, 589, 826, 886, 1052, and 1316

**Step 1: Write focused failing tests**

Extract or test through a narrow public seam for rollout confirmation. Assert both scopes create a confirmation whose `deploy_opts` is a keyword list and contains the expected values:

```elixir
assert confirmation.scope == :cluster
assert confirmation.target_hosts == ["root@node-a", "root@node-b"]
assert Keyword.get(confirmation.deploy_opts, :hosts) == confirmation.target_hosts
assert Keyword.get(confirmation.deploy_opts, :target_nodes) == confirmation.target_nodes
```

Also cover a selected node missing from the live cluster: it must be handled as a safe selected/cluster fallback, not a `BadMapError`.

**Step 2: Verify RED**

```bash
nix develop -c mix test test/nix_swarm_tui_test.exs --only test
```

If the test file has no tags, run only the named tests found via `mix test test/nix_swarm_tui_test.exs:<line>`.

Expected: existing `BadMapError` from `Map.get/2` on a keyword list.

**Step 3: Implement minimally**

Keep `rollout_base_opts/1` as a keyword list and use `Keyword.get/3` / `Keyword.put/3` consistently. Remove both erroneous `Map.get(%{overview: state.overview})` calls. Do not convert the full TUI state or deploy options to maps; the deployment API is already keyword-oriented.

After the executor/API corrections, re-evaluate TUI refresh tests that failed only because remote `cluster_logs/2` crashed; do not add TUI-specific error swallowing for an API bug already fixed in Task 4.

**Step 4: Verify GREEN**

```bash
nix develop -c mix test test/nix_swarm_tui_test.exs
```

Expected: rollout confirmation, queued update, selected-machine switch, stale-refresh, and dry-run hotkey tests pass.

**Step 5: Commit**

```bash
git add lib/nix_swarm/tui.ex test/nix_swarm_tui_test.exs
git commit -m "fix: preserve keyword deploy options in TUI rollouts"
```

---

### Task 6: Resolve deployment host policy and command-test drift

**Objective:** Align deploy plan behavior, starter configuration, and tests around one documented source of deployment hosts.

**Files:**
- Modify: `lib/nix_swarm/deploy.ex:46-87,459-491`
- Modify: `test/nix_swarm_deploy_test.exs`
- Possibly modify: `examples/config/cluster/cluster.nix`
- Possibly modify: `examples/config/machines/*.nix`
- Modify: `README.md` and/or `docs/OPERATIONS.md` if behavior changes

**Decision required before implementation:**

Choose one policy and encode it in both product behavior and tests:

1. **`deployHost` is authoritative** (recommended): `cluster/cluster.nix` determines real remote targets; machine file names only supply local module validation. Update tests to expect `.local` values (or the actual configured values) and ensure every starter node has a valid deploy host.
2. **Explicit CLI host selection is authoritative:** do not overwrite a user-specified `--hosts` with `deployHost`; use configured hosts only as defaults. Update `filter_configured_hosts/2` accordingly and retain existing filename-stem expectation only for defaults.

**Step 1: Write failing policy tests**

Add separate tests for default host discovery and explicit host input. Include a config where a filename stem differs from `deployHost`, then assert the chosen policy precisely. Do not use ambiguous assertions that pass under either implementation.

Fix shell command assertions to inspect tokens/substring literals correctly. For example, assert the discrete quoted segment:

```elixir
assert command =~ "'ssh' '-F' '/dev/null'"
assert command =~ "'UserKnownHostsFile=/dev/null'"
```

rather than `"'ssh.*UserKnownHostsFile=/dev/null'"`, which is a literal substring under `=~` and does not perform regex matching.

**Step 2: Verify RED**

```bash
nix develop -c mix test test/nix_swarm_deploy_test.exs
```

Expected: current default-host and SSH-command expectation failures reproduce.

**Step 3: Implement the selected policy**

Make host selection deterministic, preserve ordering, and avoid silently targeting an unintended host. Keep safety checks for absolute remote paths, traversal, and unsupported whitespace. Update user-facing docs to state exactly how `--hosts`, `--host`, machine files, and `deployHost` interact.

**Step 4: Verify GREEN**

```bash
nix develop -c mix test test/nix_swarm_deploy_test.exs
```

Expected: all deploy planning, validation, safety, and generated-command tests pass.

**Step 5: Commit**

```bash
git add lib/nix_swarm/deploy.ex test/nix_swarm_deploy_test.exs examples/config README.md docs
git commit -m "fix: align deployment target planning with cluster config"
```

---

### Task 7: Remove build warnings and restore formatting

**Objective:** Make development, release builds, and CI output clean after functional behavior is green.

**Files:**
- Modify: `lib/nix_swarm/cluster/rebuild.ex:79`
- Modify: `lib/nix_swarm/deploy.ex:239,287`
- Modify: `lib/nix_swarm/executor.ex:35-48`
- Modify: files named by `mix format --check-formatted`
- Modify: `nix/nix-swarm/packages.nix:3-16` if the project release version is meant to be 0.5.0
- Possibly modify: `mix.exs:7` only if the chosen release version is 0.4.1

**Step 1: Capture baseline warnings in dedicated checks**

```bash
nix develop -c mix compile --force --warnings-as-errors
nix build .#cluster --no-link --print-build-logs
```

Expected: current warning set includes unused `short`, unused `status`, outdented heredoc, and invalid `reraise` reference.

**Step 2: Make behavior-preserving fixes**

- Remove or use `short` in `Cluster.Rebuild`.
- Rename an intentionally unused match value to `_status`.
- Indent the Nix heredoc in `Deploy` in the Elixir formatter-compatible way while preserving its rendered content; test the exact generated command if it is behaviorally relevant.
- Complete Task 1’s correction to invalid `reraise` behavior.
- Run `mix format` once after behavior tests are green.
- Reconcile the Nix package version with `mix.exs` and document the intended release version. If the 0.4.1 Nix version is intentional compatibility metadata, add an explicit comment/test; otherwise set it to 0.5.0.

**Step 3: Verify clean output**

```bash
nix develop -c mix format --check-formatted
nix develop -c mix compile --force --warnings-as-errors
nix develop -c mix escript.build
nix build .#cluster --no-link --print-build-logs
```

Expected: all commands exit 0 with no Elixir compilation warnings.

**Step 4: Commit**

```bash
git add lib nix/nix-swarm/packages.nix mix.exs
git commit -m "chore: clean nix swarm build warnings"
```

---

### Task 8: Run the full local verification gate

**Objective:** Prove the full codebase and package succeed before changing the real host configuration.

**Files:**
- No production changes expected.
- Modify test files only if a remaining failure reveals a real, independently reproduced regression.

**Step 1: Run checks in dependency order**

```bash
cd /home/itm/hermes/workspace/projects/code/nix-swarm
nix develop -c mix format --check-formatted
nix develop -c mix test
nix develop -c mix escript.build
nix develop -c mix run scripts/verify_cluster.exs
nix flake check --no-build --no-write-lock-file
nix build .#operator --no-link
nix build .#cluster --no-link
```

**Step 2: Check workspace cleanliness**

```bash
git diff --check
git status --short
```

Expected: no unexpected source changes. The pre-existing untracked `AGENTS.md` must not be committed unless explicitly requested.

**Step 3: Commit only if all gates are green**

```bash
git add -A
git commit -m "test: verify nix swarm runtime and package"
```

Do not commit generated `_build/`, `deps/`, `result`, credentials, cookies, or `secrets/` content.

---

### Task 9: Deploy and verify the real NixOS `nix-swarmd` service

**Objective:** Validate systemd notification, configuration rendering, process health, and basic RPC behavior on `overlord` without performing unattended privileged operations.

**Files:**
- Inspect: target host NixOS flake/configuration that imports `nix/nix-swarm/module.nix`
- Inspect: deployed service configuration and cookie path
- Possibly modify (with explicit user approval): the host NixOS configuration outside this checkout

**Prerequisites:**

- Task 8 is fully green.
- An authorized operator is available for required `sudo nixos-rebuild switch` (Hermes must not bypass the password-required sudo boundary).
- The service’s `nodeName`, peers, firewall policy, `cookieFile`, and package output point to the tested source/revision.

**Step 1: Preflight without mutation**

```bash
systemctl list-unit-files 'nix-swarm*' --no-legend
systemctl cat nix-swarmd.service
systemctl show nix-swarmd.service \
  -p LoadState -p ActiveState -p SubState -p Type -p TimeoutStartUSec -p FragmentPath
```

Inspect the rendered environment/credentials without printing cookie values. Confirm the unit uses `Type=notify`, has `NIX_SWARM_CONFIG_PATH`, a valid `RELEASE_NODE`, a distribution port, and a readable credential binding.

**Step 2: Apply the service configuration with human-authorized sudo**

The operator runs the project’s approved host rebuild command. Use the host’s actual flake target; do not guess a `.#name`:

```bash
sudo nixos-rebuild switch --flake <host-flake>#<host-name>
```

**Step 3: Start and inspect service**

```bash
sudo systemctl daemon-reload
sudo systemctl restart nix-swarmd
systemctl is-active nix-swarmd
systemctl show nix-swarmd.service -p ActiveState -p SubState -p Result -p ExecMainStatus
journalctl -u nix-swarmd --since '5 minutes ago' --no-pager
```

Expected: `active`, `running`, successful result, and no systemd startup timeout. If it times out, capture the full unit definition and journal, then return to a new root-cause investigation; do not increase `TimeoutStartSec` blindly.

**Step 4: Verify node-level behavior**

From a packaged operator with a securely supplied cookie, perform non-mutating status/RPC checks first:

```bash
swarm --target <configured-node-name>
```

If interactive TUI inspection is impractical, use the project’s supported CLI/API status path. Verify configured peers and live nodes, then check one safe operational call in a controlled environment. Do not run remote apply/rebuild as part of this verification unless separately authorized.

**Step 5: Record outcome**

Report unit state, package path/revision, config generation, test commands, and whether status/RPC checks succeeded. Redact cookies and all tokens.

---

## Final acceptance criteria

- [ ] `mix format --check-formatted` passes.
- [ ] `mix compile --force --warnings-as-errors` passes.
- [ ] `mix test` passes with zero failures.
- [ ] `mix escript.build` passes.
- [ ] `mix run scripts/verify_cluster.exs` prints `three-node verification passed`.
- [ ] `nix flake check --no-build --no-write-lock-file` passes.
- [ ] `nix build .#operator --no-link` and `nix build .#cluster --no-link` pass.
- [ ] Invalid unit names never reach system commands.
- [ ] Fake three-node convergence works from stopped state and after a node failure.
- [ ] No unexpected generated files or secrets are added to Git.
- [ ] With human-authorized configuration application, `nix-swarmd.service` loads and stays `active (running)` on NixOS.

## Risks and decision points

- **Deployment-target policy:** The user/product owner must choose whether `deployHost` or explicit CLI `--hosts` is authoritative before Task 6 lands.
- **Systemd deployment scope:** Enabling/restarting the real service and rebuilding NixOS require explicit authorization and a human-entered sudo password. The plan intentionally keeps this as a separate final task.
- **Historical service logs:** The old startup timeout may have originated from a different package/configuration revision. Reproduce only after current automated gates pass; distinguish a current runtime defect from historical environment state.
- **Security:** Keep cookie contents and any previously exposed GitHub token out of test output, commits, plans, and logs. Rotate the exposed GitHub token separately before using it again.
