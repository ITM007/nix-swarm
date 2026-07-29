# Nix-Defined Caddy Edge Routing Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add a supported, fully Nix-defined Caddy edge-routing pattern in which users configure Caddy through the standard NixOS module, Nix-Swarm keeps `caddy.service` on an explicitly allowed edge node, `cluster apply` deploys Caddy changes, and Caddy health checks select the currently active service endpoints without Nix-Swarm rewriting files or calling Caddy's Admin API.

**Architecture:** Keep Caddy as the HTTP/TLS data plane and Nix-Swarm as the code-first deployment/placement control plane. The user declares the complete Caddy configuration in `.nix`; the reverse proxy lists the finite matrix of candidate node/slot endpoints, and Caddy's active health checks exclude endpoints whose Nix-Swarm-owned systemd slot is not running. Caddy itself is a normal NixOS `services.caddy` service on an explicitly selected edge node and is also declared as a one-replica Nix-Swarm service with `allowedNodes`, so placement/status/reconciliation verify the exact `caddy.service` unit without introducing Caddy-specific runtime mutation.

**Tech Stack:** NixOS modules, standard `services.caddy`, Caddy reverse proxy health checks, systemd, existing Elixir/OTP placement and reconciliation, existing native `nixos-rebuild` deployment and rollback, ExUnit, Nix flake checks, NixOS VM tests, optional Docker acceptance.

---

## Product Contract and Scope

### Supported behavior

1. The user writes all Caddy routing and TLS policy in `.nix` through the standard NixOS Caddy module.
2. The designated edge machine imports that Caddy module; non-edge machines do not enable Caddy.
3. The shared Nix-Swarm service model declares exactly one `caddy.service` replica with an explicit `allowedNodes` edge-node allowlist.
4. Application backends are represented as a static, finite list of every valid node/slot endpoint.
5. Caddy actively health-checks those endpoints and sends traffic only to healthy instances.
6. A runtime slot move needs no file update: the old node/slot endpoint fails health checks and the new node/slot endpoint becomes healthy.
7. A user edit to Caddy policy follows the normal flow:

   ```bash
   nix-swarm cluster plan --source .
   nix-swarm cluster apply --source . --yes
   ```

8. The existing rollout prebuilds the complete NixOS closure, activates hosts sequentially, checks the observed Nix-Swarm service state, and rolls attempted hosts back if Caddy or cluster health does not converge.

### Explicit non-goals

- No generated or agent-written Caddyfile.
- No runtime Caddy Admin API mutations.
- No file watcher or implicit apply after source edits.
- No new JSON/YAML/TOML configuration.
- No dynamic service registry, routing mesh, virtual IP, or DNS controller.
- No automatic TLS-storage replication or Caddy-node failover in the first version.
- No parsing of raw `.nix` source by Elixir agents.
- No Caddy-specific fields in `services.nix-swarm.services.*`.
- No automatic routing for stateful/single-writer services.

### First-version operating assumptions

- One designated Caddy edge node is used.
- A router, DNS record, or port-forward directs clients to that edge node.
- Backend traffic uses a trusted private or overlay network.
- The backend candidate set is bounded by configured nodes and service slot capacity.
- Each replica slot has a stable port independent of owner node; for the example, slot `0` uses `8080` and slot `1` uses `8081`.
- Backend services bind to their private/overlay interface or an appropriately firewalled non-loopback address.
- The example uses HTTP/local naming and does not depend on public ACME issuance.
- Production TLS state and edge-node replacement remain operator-owned and are documented honestly.

---

## Task 1: Lock the Nix-Only Caddy Boundary with Characterization Tests

**Objective:** Establish failing policy tests proving that Caddy is configured only through Nix, placed on one explicit edge node, and never mutated by the Elixir runtime.

**Files:**
- Modify: `test/nix_swarm_project_policy_test.exs`
- Modify: `test/nix_swarm_security_test.exs`
- Test: `test/nix_swarm_project_policy_test.exs`
- Test: `test/nix_swarm_security_test.exs`

**Step 1: Add a failing project-policy test**

Add a test that reads the planned example files and asserts:

```elixir
test "Caddy routing is Nix-defined and has no mutable runtime control path" do
  cluster = File.read!("examples/config/cluster/cluster.nix")
  edge = File.read!("examples/config/services/caddy-edge.nix")
  runtime = Path.wildcard("lib/nix_swarm/**/*.ex") |> Enum.map_join("\n", &File.read!/1)

  assert cluster =~ ~s(unitTemplate = "caddy.service")
  assert cluster =~ "allowedNodes"
  assert edge =~ "services.caddy"
  assert edge =~ "reverse_proxy"
  assert edge =~ "health_uri"

  refute runtime =~ "Caddyfile"
  refute runtime =~ "caddy reload"
  refute runtime =~ "/config/apps/http"
  refute runtime =~ "localhost:2019"
end
```

Also assert that the edge Caddy module contains only `.nix`-authored configuration and that no generated `*.caddy`, JSON, or runtime routing-state artifact is introduced.

**Step 2: Add a failing security test**

Assert that Nix-Swarm's polkit-managed unit set includes exact unit names only and does not authorize arbitrary Caddy configuration or shell commands. The test should prove that the integration manages only `caddy.service` through the existing exact-unit systemd path.

**Step 3: Run the focused tests and verify RED**

Run:

```bash
nix develop --command mix test \
  test/nix_swarm_project_policy_test.exs \
  test/nix_swarm_security_test.exs --trace
```

Expected: failure because `examples/config/services/caddy-edge.nix` and the Caddy placement declaration do not yet exist.

**Step 4: Commit the red tests**

```bash
git add test/nix_swarm_project_policy_test.exs test/nix_swarm_security_test.exs
git commit -m "test: define nix-only caddy routing contract"
```

---

## Task 2: Repair the Multi-Node Example Before Adding Caddy

**Objective:** Make `examples/config` conform to the current reduced service and node schema so it can serve as the authoritative multi-node Caddy example.

**Files:**
- Modify: `examples/config/cluster/cluster.nix`
- Modify: `test/nix_swarm_project_policy_test.exs`

**Step 1: Add failing assertions for the current public schema**

Assert the example contains none of the removed fields:

```elixir
for forbidden <- ["labels", "preferredNodes", "constraints", "maxReplicasPerNode"] do
  refute cluster =~ forbidden
end
```

Assert `example-web` uses:

```nix
example-web = {
  replicas = 2;
  unitTemplate = "example-web@%{slot}.service";
  allowedNodes = [
    "nix-swarm@example-node-a.local"
    "nix-swarm@example-node-b.local"
  ];
};
```

**Step 2: Run the test and verify RED**

Run:

```bash
nix develop --command mix test test/nix_swarm_project_policy_test.exs --trace
```

Expected: failure on the stale `labels` and `preferredNodes` example syntax.

**Step 3: Make the minimal example cleanup**

- Remove node labels.
- Replace `preferredNodes` with `allowedNodes`.
- Set the exact `example-web@%{slot}.service` template.
- Keep node deployment identity and availability in Nix.
- Do not add compatibility parsing to Elixir or the NixOS module.

**Step 4: Verify GREEN**

Run the focused test again and expect it to pass.

**Step 5: Commit**

```bash
git add examples/config/cluster/cluster.nix test/nix_swarm_project_policy_test.exs
git commit -m "fix: align multi-node example with service contract"
```

---

## Task 3: Define Caddy Placement as a Normal Nix-Swarm Service

**Objective:** Ensure the existing placement and reconciler keep the exact `caddy.service` unit on the designated edge node without adding Caddy-specific runtime code.

**Files:**
- Modify: `examples/config/cluster/cluster.nix`
- Modify: `test/nix_swarm_config_files_test.exs`
- Modify: `test/nix_swarm_placement_test.exs`
- Modify: `test/nix_swarm_reconciler_test.exs`

**Step 1: Write failing placement and rendered-config tests**

Build a two-node configuration containing:

```nix
caddy = {
  replicas = 1;
  unitTemplate = "caddy.service";
  allowedNodes = [ "nix-swarm@example-node-a.local" ];
};
```

Assert:

- placement assigns `caddy.service` only to node A;
- node B never owns `caddy.service`;
- the rendered Erlang terms include the exact unit template and allowed node;
- the reconciler starts `caddy.service` on node A;
- the reconciler does not attempt to start it on node B;
- no generic Caddy command or configuration-file write is performed.

**Step 2: Run focused tests and verify RED**

Run:

```bash
nix develop --command mix test \
  test/nix_swarm_config_files_test.exs \
  test/nix_swarm_placement_test.exs \
  test/nix_swarm_reconciler_test.exs --trace
```

Expected: the new fixture assertions fail before the Caddy service entry is present.

**Step 3: Add the Caddy service entry to the shared cluster module**

Use the existing generic service fields only. Do not introduce `proxy`, `route`, `port`, `Caddyfile`, or other Caddy-specific fields into `nix/nix-swarm/module.nix` or `NixSwarm.Service`.

**Step 4: Run focused tests and verify GREEN**

Expected: Caddy placement and exact-unit reconciliation tests pass.

**Step 5: Commit**

```bash
git add \
  examples/config/cluster/cluster.nix \
  test/nix_swarm_config_files_test.exs \
  test/nix_swarm_placement_test.exs \
  test/nix_swarm_reconciler_test.exs
git commit -m "feat: place caddy as a managed edge service"
```

---

## Task 4: Add the User-Owned NixOS Caddy Module

**Objective:** Configure Caddy entirely through the standard NixOS module on the edge node, with static candidate backends and active health checks that follow Nix-Swarm slot movement.

**Files:**
- Create: `examples/config/services/caddy-edge.nix`
- Modify: `examples/config/machines/example-node-a.nix`
- Modify: `examples/config/machines/example-node-b.nix`
- Modify: `examples/config/cluster/services/example-web.nix`
- Test: `test/nix_swarm_project_policy_test.exs`

**Step 1: Write failing source-contract tests**

Assert:

- only node A imports `../services/caddy-edge.nix`;
- node B does not import or enable Caddy;
- the Caddy module uses `services.caddy.enable = true`;
- the reverse proxy lists all four valid node/slot candidates;
- active health checks are configured;
- backend ports are exposed only on the named private interface;
- the workload is not bound exclusively to `127.0.0.1`.

**Step 2: Run the focused policy test and verify RED**

Expected: failure because the edge module does not exist.

**Step 3: Create the Caddy module**

Use standard NixOS configuration shaped like:

```nix
{ ... }:
{
  services.caddy = {
    enable = true;
    virtualHosts."http://app.example.internal".extraConfig = ''
      reverse_proxy \
        example-node-a.local:8080 \
        example-node-a.local:8081 \
        example-node-b.local:8080 \
        example-node-b.local:8081 {
          health_uri /
          health_interval 5s
          health_timeout 2s
          fail_duration 10s
        }
    '';
  };

  networking.firewall.interfaces.wg0.allowedTCPPorts = [ 80 443 ];
}
```

Adjust syntax to match the pinned nixpkgs Caddy module and validate with Nix evaluation. Use an HTTP-only internal example to avoid requiring public DNS or ACME during tests.

**Step 4: Import Caddy only on the edge node**

Add `../services/caddy-edge.nix` to `example-node-a.nix`. Do not import it in `example-node-b.nix`.

**Step 5: Make backend endpoints remotely reachable but private**

Update `example-web@.service` so slot `i` listens on `8080 + i` on a non-loopback address. Open only ports `8080` and `8081` on the example private interface (`wg0`), not globally. Preserve systemd hardening.

**Step 6: Explain why the candidate matrix works**

Add comments in the Nix module:

- slot 0 always maps to port 8080;
- slot 1 always maps to port 8081;
- only the owning node runs each slot;
- Caddy marks inactive node/slot combinations unhealthy;
- movement changes endpoint health rather than configuration.

**Step 7: Run focused tests and Nix formatting**

```bash
nix develop --command mix test test/nix_swarm_project_policy_test.exs --trace
nix fmt examples/config/services/caddy-edge.nix \
  examples/config/machines/example-node-a.nix \
  examples/config/machines/example-node-b.nix \
  examples/config/cluster/services/example-web.nix
```

Expected: policy tests pass and Nix files are formatted.

**Step 8: Commit**

```bash
git add examples/config test/nix_swarm_project_policy_test.exs
git commit -m "feat: add nix-defined caddy edge example"
```

---

## Task 5: Add Nix Evaluation Proof for Edge-Only Caddy

**Objective:** Prove at Nix evaluation time that Caddy is enabled only on the designated edge node and that the complete configuration builds through the existing deployment path.

**Files:**
- Modify: `flake.nix`
- Optionally create: `nix/tests/caddy-edge.nix`
- Modify: `test/nix_swarm_project_policy_test.exs`

**Step 1: Add a failing flake check fixture**

Create or extend a `nixosSystem` evaluation fixture with two configurations:

- node A imports the Caddy edge module and has `services.caddy.enable = true`;
- node B contains the backend service but has `services.caddy.enable = false`;
- both evaluate the shared Nix-Swarm topology;
- Caddy placement is restricted to node A.

Assertions should inspect evaluated configuration, not parse source text alone:

```nix
assert edge.config.services.caddy.enable;
assert !worker.config.services.caddy.enable;
assert edge.config.systemd.services ? caddy;
```

Also assert that both NixOS closures evaluate successfully.

**Step 2: Run flake evaluation and verify RED**

```bash
nix flake check --no-build --no-write-lock-file --show-trace
```

Expected: failure before the Caddy fixture is wired correctly.

**Step 3: Wire the minimal Caddy evaluation check**

Do not add a custom Caddy package or dependency to the Elixir release. Reuse nixpkgs' standard Caddy package and module.

**Step 4: Run flake evaluation and verify GREEN**

```bash
nix flake check --no-build --no-write-lock-file --show-trace
```

Expected: all flake outputs and Caddy topology assertions evaluate successfully.

**Step 5: Commit**

```bash
git add flake.nix nix/tests test/nix_swarm_project_policy_test.exs
git commit -m "test: evaluate edge-only caddy topology"
```

---

## Task 6: Verify Apply, Caddy Failure, and Rollback Semantics

**Objective:** Prove that Caddy changes use the existing plan/apply transaction and that an invalid or unhealthy Caddy activation causes bounded deployment failure and attempted-host rollback.

**Files:**
- Modify: `test/nix_swarm_deploy_test.exs`
- Modify: `test/nix_swarm_deploy_state_machine_test.exs`
- Modify: `test/nix_swarm_deploy_plan_test.exs`
- Modify: `test/nix_swarm_api_test.exs`

**Step 1: Add a failing deployment-plan test**

Assert that a source change to the edge Caddy module is included by the normal NixOS closure build and does not create a separate Caddy deployment command. The operator plan should still contain only native Nix build/rebuild operations.

**Step 2: Add a failing health-gate test**

Model the edge host activating a generation where `caddy.service` is failed or missing from the expected local service status. Assert:

- the deployment does not report success;
- the attempted edge host is included in rollback candidates;
- unattempted hosts remain untouched;
- no Caddyfile mutation or Admin API rollback occurs;
- rollback uses the previous NixOS generation.

**Step 3: Add an API/status characterization test**

Given a configured `caddy` Nix-Swarm service, assert `cluster_status` reports the `caddy.service` placement and local systemd state through the existing generic service representation. Do not add special `caddy` fields to the query protocol.

**Step 4: Run focused tests and verify RED**

```bash
nix develop --command mix test \
  test/nix_swarm_deploy_test.exs \
  test/nix_swarm_deploy_state_machine_test.exs \
  test/nix_swarm_deploy_plan_test.exs \
  test/nix_swarm_api_test.exs --trace
```

**Step 5: Make only minimal generic fixes if tests expose a gap**

The intended result is that existing generic deployment and service-health logic is sufficient. If the tests reveal that final health can pass while expected `caddy.service` is failed, tighten the generic `healthy_overview?/2` predicate for all managed services rather than adding Caddy-specific logic.

**Step 6: Run focused tests and verify GREEN**

Expected: plan/apply and rollback behavior passes for Caddy as an ordinary managed systemd service.

**Step 7: Commit**

```bash
git add test/nix_swarm_deploy_test.exs \
  test/nix_swarm_deploy_state_machine_test.exs \
  test/nix_swarm_deploy_plan_test.exs \
  test/nix_swarm_api_test.exs \
  lib/nix_swarm/deploy.ex
git commit -m "test: verify caddy deployment rollback semantics"
```

Only include `lib/nix_swarm/deploy.ex` if a generic health-gate correction is actually necessary.

---

## Task 7: Add a Real NixOS VM Caddy Smoke Test

**Objective:** Exercise Caddy, systemd, and one managed backend in a real NixOS VM rather than relying only on source assertions.

**Files:**
- Modify: `flake.nix`
- Optionally create: `nix/tests/caddy-edge-vm.nix`
- Modify: `docs/TESTING.md`

**Step 1: Add a failing VM test**

The VM should:

1. boot with the standard Caddy NixOS module enabled;
2. run a Nix-Swarm-managed HTTP backend;
3. wait for `nix-swarmd.service` and `caddy.service`;
4. request the Caddy frontend with the expected `Host` header;
5. receive the backend's known response;
6. verify Caddy's configuration is represented by the immutable NixOS generation;
7. verify no runtime-generated Caddy configuration exists under `/var/lib/nix-swarm` or `/run/nix-swarm`.

Representative test-script assertions:

```python
edge.wait_for_unit("nix-swarmd.service")
edge.wait_for_unit("caddy.service")
edge.wait_for_unit("example-web.service")
edge.succeed("curl -fsS -H 'Host: app.example.internal' http://127.0.0.1/ | grep -x ok")
edge.succeed("test ! -e /run/nix-swarm/Caddyfile")
```

**Step 2: Build the VM check and verify RED**

```bash
nix build .#checks.x86_64-linux.caddy-vm \
  --no-link --print-build-logs
```

Expected: failure until the VM fixture and correct Caddy/backend configuration are complete.

**Step 3: Complete the minimal VM fixture**

Use loopback only inside the one-node VM test. Keep the multi-node example's private-interface behavior separate.

**Step 4: Build and verify GREEN**

Expected: the Caddy frontend returns the known backend response and both units are active.

**Step 5: Document the test layer**

Add `caddy-vm` to the test inventory. Clearly distinguish this one-node routing proof from multi-node failover evidence.

**Step 6: Commit**

```bash
git add flake.nix nix/tests docs/TESTING.md
git commit -m "test: add nixos caddy edge smoke coverage"
```

---

## Task 8: Add Optional Multi-Node Movement Acceptance Coverage

**Objective:** Prove that static candidate endpoints plus Caddy health checks continue routing when a stateless slot moves between eligible nodes, without changing Caddy configuration.

**Files:**
- Modify: `scripts/docker-scenarios`
- Modify: `scripts/docker-stack`
- Modify: Docker/Nix fixtures under `docker/` as discovered during implementation
- Modify: `test/nix_swarm_docker_harness_test.exs`
- Modify: `docs/TESTING.md`

**Step 1: Add a failing harness contract test**

Require a stable scenario ID such as `ROUTING-001` or `CADDY-001` that:

1. starts Caddy on the designated edge node;
2. records the immutable Caddy config hash;
3. verifies requests reach the current backend owner;
4. stops or drains that owner;
5. waits for Nix-Swarm placement and Caddy health convergence;
6. verifies requests reach the replacement owner;
7. verifies the Caddy config hash is unchanged.

**Step 2: Run the harness contract test and verify RED**

```bash
nix develop --command mix test test/nix_swarm_docker_harness_test.exs --trace
```

**Step 3: Implement the minimum live scenario**

Do not add runtime configuration generation. The scenario must demonstrate that only endpoint health changes.

**Step 4: Run live acceptance when Docker is available**

```bash
./scripts/docker-stack reset
./scripts/docker-stack up
./scripts/docker-stack scenario CADDY-001
./scripts/docker-stack reset
```

Expected:

- requests succeed before movement;
- requests recover after bounded convergence;
- the selected backend owner changes;
- Caddy configuration does not change;
- no duplicate stateful service is involved.

If Docker is unavailable, report this layer as unavailable rather than passed. The NixOS VM test remains mandatory.

**Step 5: Commit**

```bash
git add scripts docker test/nix_swarm_docker_harness_test.exs docs/TESTING.md
git commit -m "test: cover caddy routing across service movement"
```

---

## Task 9: Document the Operator Workflow and Failure Boundaries

**Objective:** Give operators a concise, accurate Caddy setup and recovery guide without implying a built-in reverse proxy, routing mesh, or automatic certificate failover.

**Files:**
- Modify: `README.md`
- Modify: `docs/CONFIG_REFERENCE.md`
- Modify: `docs/OPERATIONS.md`
- Modify: `docs/SWARM_PARITY.md`
- Modify: `docs/SECURITY.md`
- Modify: `examples/config/README.md` if present; otherwise create it only if the multi-node example lacks an entry point
- Modify: `test/nix_swarm_project_policy_test.exs`

**Step 1: Add failing documentation-contract tests**

Assert the docs state:

- Caddy is optional and supplied by the standard NixOS module;
- the user owns all Caddy policy in `.nix`;
- Nix-Swarm never writes Caddy files or uses the Admin API;
- `cluster plan/apply` deploys Caddy edits;
- static candidate endpoints plus active health checks handle slot movement;
- only the edge node enables Caddy;
- clients still require DNS/router reachability to the edge node;
- backend ports must be restricted to a private network;
- first-version edge failover and certificate-state replication are not managed;
- stateful services must not use automatic duplicate/failover routing without application-owned coordination.

**Step 2: Run the policy test and verify RED**

```bash
nix develop --command mix test test/nix_swarm_project_policy_test.exs --trace
```

**Step 3: Write the operator workflow**

Include:

```bash
$EDITOR examples/config/services/caddy-edge.nix
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
nix-swarm cluster status --target nix-swarm@example-node-a.local
curl -H 'Host: app.example.internal' http://EDGE_NODE/
```

Document normal recovery:

- if a backend owner fails, wait for placement and Caddy health convergence;
- if Caddy fails after an apply, inspect `systemctl status caddy` and `journalctl -u caddy`, then rely on attempted-host NixOS rollback or correct Nix and reapply;
- if the edge node fails, the backend cluster may continue but external HTTP ingress is unavailable until the edge node or an externally managed alternative returns;
- direct manual Caddy edits are drift and will be replaced by the next NixOS activation.

**Step 4: Remove stale routing language**

Replace any claim that ingress is compatibility metadata with the sharper boundary: Nix-Swarm does not provide ingress itself, but it supports deploying a user-authored standard NixOS Caddy service as an ordinary workload.

Also remove stale `labels` and `resourceLimits` examples found in `docs/CONFIG_REFERENCE.md` so the Caddy documentation builds on the current public contract.

**Step 5: Verify documentation tests GREEN**

Run the focused policy test and check links/commands manually.

**Step 6: Commit**

```bash
git add README.md docs examples/config test/nix_swarm_project_policy_test.exs
git commit -m "docs: add nix-defined caddy routing workflow"
```

---

## Task 10: Full Review and Release Verification

**Objective:** Verify the Caddy integration preserves Nix-only authority, generic systemd orchestration, security boundaries, rollback behavior, and release quality.

**Files:**
- Review all changed files
- Do not add generated build artifacts to Git

**Step 1: Search for forbidden runtime mutation paths**

Run:

```bash
rg -n 'Caddyfile|caddy reload|localhost:2019|/config/apps/http|Admin API' lib test nix examples docs
```

Expected:

- no Caddy mutation path under `lib/`;
- documentation may mention forbidden behavior only to state it is unsupported;
- no generated mutable Caddy state is committed.

**Step 2: Review authority and placement invariants**

Verify:

- user Caddy configuration exists only in `.nix`;
- Caddy is enabled only in the edge machine closure;
- the shared service entry allows Caddy placement only on the edge node;
- backend candidate addresses are static and bounded;
- backend health determines request eligibility;
- Caddy unit status appears through generic cluster service status;
- edge failure is not misrepresented as automatic ingress failover.

**Step 3: Run formatting and compilation**

```bash
nix develop --command bash -c '
  mix format --check-formatted &&
  mix clean &&
  mix compile --warnings-as-errors
'
```

Expected: all commands pass with no compiler warnings.

**Step 4: Run focused tests**

```bash
nix develop --command mix test \
  test/nix_swarm_project_policy_test.exs \
  test/nix_swarm_security_test.exs \
  test/nix_swarm_config_files_test.exs \
  test/nix_swarm_placement_test.exs \
  test/nix_swarm_reconciler_test.exs \
  test/nix_swarm_deploy_test.exs \
  test/nix_swarm_deploy_state_machine_test.exs \
  test/nix_swarm_deploy_plan_test.exs \
  test/nix_swarm_api_test.exs --seed 0
```

Expected: all focused tests pass.

**Step 5: Run the full Mix gate**

```bash
nix develop --command mix test --warnings-as-errors --cover
```

Expected: all non-explicitly-unavailable tests pass and total coverage remains at or above the configured 65% threshold.

**Step 6: Run Nix evaluation and VM checks**

```bash
nix flake check --no-write-lock-file --print-build-logs
nix build .#checks.x86_64-linux.caddy-edge-vm --no-link --print-build-logs
```

Expected: flake evaluation and the real Caddy VM test pass.

**Step 7: Run shell and live checks when available**

```bash
shellcheck scripts/*
./scripts/docker-stack reset
./scripts/docker-stack up
./scripts/docker-stack scenario CADDY-001
./scripts/docker-stack reset
```

Report unavailable tools or Docker access separately; never claim unavailable evidence passed.

**Step 8: Review the complete diff**

```bash
git diff --check
git status --short
git diff --stat
git diff
```

Confirm there are no credentials, public ACME dependencies, private infrastructure details, generated Caddy state, build outputs, or unrelated changes.

**Step 9: Request independent review**

Review first for specification compliance, then for code quality/security. Require explicit confirmation that:

- no runtime mutation path was added;
- no Caddy-specific control plane leaked into the Elixir runtime;
- edge-only placement is deterministic;
- backend movement works by health state, not file changes;
- rollback remains native NixOS rollback;
- network and TLS limitations are honest.

**Step 10: Commit the final cleanup**

```bash
git add -A
git commit -m "feat: support nix-defined caddy edge routing"
```

Do not push until all available checks pass and unavailable live evidence is reported.

---

## Files Likely to Change

### Expected production/example files

- `examples/config/cluster/cluster.nix`
- `examples/config/cluster/services/example-web.nix`
- `examples/config/services/caddy-edge.nix` (new)
- `examples/config/machines/example-node-a.nix`
- `examples/config/machines/example-node-b.nix`
- `flake.nix`
- `nix/tests/caddy-edge.nix` or `nix/tests/caddy-edge-vm.nix` (optional new fixture)

### Expected tests

- `test/nix_swarm_project_policy_test.exs`
- `test/nix_swarm_security_test.exs`
- `test/nix_swarm_config_files_test.exs`
- `test/nix_swarm_placement_test.exs`
- `test/nix_swarm_reconciler_test.exs`
- `test/nix_swarm_deploy_test.exs`
- `test/nix_swarm_deploy_state_machine_test.exs`
- `test/nix_swarm_deploy_plan_test.exs`
- `test/nix_swarm_api_test.exs`
- `test/nix_swarm_docker_harness_test.exs`

### Expected documentation

- `README.md`
- `docs/CONFIG_REFERENCE.md`
- `docs/OPERATIONS.md`
- `docs/SWARM_PARITY.md`
- `docs/SECURITY.md`
- `docs/TESTING.md`
- `examples/config/README.md` if needed

### Files that should not need production changes

- `lib/nix_swarm/service.ex`
- `lib/nix_swarm/config.ex`
- `lib/nix_swarm/reconciler.ex`
- `lib/nix_swarm/api.ex`
- `nix/nix-swarm/module.nix`

If these generic runtime files require changes, stop and prove the gap with a failing test first. Do not add Caddy-specific branches.

---

## Acceptance Criteria

- [ ] Caddy configuration is entirely user-authored `.nix` using the standard NixOS Caddy module.
- [ ] Nix-Swarm does not create, edit, watch, or distribute a mutable Caddyfile.
- [ ] Nix-Swarm does not call Caddy's Admin API.
- [ ] Caddy is enabled only on the declared edge node.
- [ ] `caddy.service` is represented as one generic Nix-Swarm service restricted by `allowedNodes`.
- [ ] Cluster status reports the Caddy unit through existing service status.
- [ ] Application slots use stable per-slot ports and private-network reachability.
- [ ] Caddy lists the finite node/slot endpoint matrix and actively health-checks it.
- [ ] A stateless slot can move without any Caddy configuration change.
- [ ] Editing Caddy Nix and running plan/apply deploys the new NixOS generation.
- [ ] Invalid or unhealthy Caddy activation fails the health gate and attempts native NixOS rollback.
- [ ] No virtual IP, routing mesh, automatic edge failover, or TLS storage replication is claimed.
- [ ] NixOS VM routing smoke test passes.
- [ ] Multi-node movement test passes when Docker/live infrastructure is available.
- [ ] Full format, warnings-as-errors compilation, test coverage, and Nix checks pass.

---

## Risks and Tradeoffs

### Edge node is a single ingress failure point

The backend cluster may continue after the edge node fails, but clients lose the Caddy entry point. The first version documents this rather than adding virtual-IP or multi-edge coordination. A future explicit scope could add two Caddy nodes plus external DNS/router failover.

### Static candidate lists grow with nodes × slot capacity

For the target market, this is acceptable and keeps runtime state simple. Validate and document a practical bound. Do not generate hundreds or thousands of speculative endpoints without a measured need.

### Health convergence creates brief downtime

After movement, Caddy must mark the old endpoint unhealthy and the new endpoint healthy. Tune only the example's Caddy health settings; do not reintroduce broad Nix-Swarm timing knobs.

### Port identity must remain stable

The pattern depends on a deterministic slot-to-port mapping. Services that allocate random ports are outside this first version. Document the mapping beside the systemd unit and Caddy configuration.

### Stateful workloads remain unsafe for automatic movement

Caddy health checks do not provide fencing, replication, or single-writer safety. The example and docs must limit this pattern to stateless or externally coordinated services.

### Caddy certificate state is separate from routing policy

Nix defines Caddy's policy but not safe certificate-state replication. A failed edge node may require restoring its state or using an externally managed certificate/DNS design. Do not hide this boundary.

### NixOS Caddy activation behavior must be verified, not assumed

The implementation must verify how the pinned nixpkgs module validates and reloads Caddy. The deployment's final health gate is the backstop; if Caddy reload failure is not reflected in unit health, tighten generic service health checks with a test.

---

## Open Questions to Resolve During Implementation

1. Which private interface name should examples use (`wg0`, `tailscale0`, or an explicit placeholder)? Prefer the existing `wg0` convention unless tests require otherwise.
2. Does the pinned NixOS Caddy module reject invalid configuration during build, activation, or service reload? Record the observed behavior in tests and documentation.
3. Should the multi-node live test use HTTP only or a locally trusted TLS certificate? Prefer HTTP for deterministic release tests; document TLS separately.
4. What candidate-matrix bound is reasonable for the product? Start with the declared replica capacity and small-node target; avoid adding a configurable global limit unless a failing evaluation test demonstrates the need.
5. Does final deployment health already reject a failed `caddy.service` in all mixed-generation cases? If not, fix the generic health invariant rather than creating a Caddy exception.
