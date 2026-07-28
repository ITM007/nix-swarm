# Replace the Operator CLI and TUI with a WebUI Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Replace the user-facing `nix-swarm` CLI and Ratatui TUI with a separately packaged, authenticated WebUI while preserving Nix as the only desired-state model, the agent's leaderless architecture, and the restricted SSH/Unix-socket operator boundary.

**Architecture:** Keep `nix-swarmd` unchanged as a headless agent with no HTTP listener. Add a separate Phoenix LiveView operator application that runs on an operator workstation or dedicated management host, queries one agent through the existing `NixSwarm.Remote` SSH-to-`nix-swarm-query` path, and invokes existing Nix deployment modules server-side. Extract reusable orchestration currently embedded in `NixSwarm.CLI` and `NixSwarm.TUI` into a presentation-neutral `NixSwarm.Operator` context before deleting those interfaces.

**Tech Stack:** Elixir 1.20, OTP 28, Phoenix 1.8, Phoenix LiveView 1.2, Bandit, Phoenix PubSub, plain CSS with minimal JavaScript, ExUnit, Phoenix.ConnTest, Phoenix.LiveViewTest, Nix flakes, and NixOS systemd modules. Do not add Ecto, a SQL database, Node/Tailwind, an SPA framework, Oban, or a public REST API in the first implementation.

---

## Recommendation

Use **Phoenix LiveView**, but run it as a **separate operator release**, not inside `nix-swarmd` and not on every cluster node.

```text
Browser
  |
  | authenticated HTTP/WebSocket (loopback by default)
  v
nix-swarm-web on an operator host
  |-- reads the Nix source checkout
  |-- evaluates/builds/deploys NixOS closures
  |-- owns server-side SSH credentials and known_hosts
  |
  | hardened SSH to nix-swarm-query
  v
one nix-swarmd agent's bounded Unix socket
  |
  v
trusted BEAM peers -> deterministic placement -> local systemd
```

The browser must never receive the BEAM cookie, an SSH private key, arbitrary shell access, or direct access to an agent query socket.

### Why LiveView fits

- Nix-Swarm is already Elixir/OTP, so the UI uses the same language and supervision model.
- Dashboard refresh, topology, filtering, logs, deployment progress, reconnects, and confirmations are stateful interactions that LiveView handles directly.
- `Phoenix.LiveViewTest` covers most behavior without a heavyweight browser suite.
- Server-rendered HTML avoids inventing and securing a JSON API solely for an SPA.
- Phoenix provides routing, sessions, CSRF, origin checks, WebSocket lifecycle, PubSub, structured errors, and mature test support.

### Why not a smaller stack?

**Plug + Bandit + server-rendered HTML + polling** is reasonable for a one-page read-only prototype. It is not the simpler long-term choice if the goal is parity with the current 5,591-line TUI: the project would hand-build sessions, CSRF, forms, reconnect behavior, components, streaming/polling, flash handling, and UI tests.

Avoid initially:

- Ecto/PostgreSQL/SQLite: Nix generations remain deployment history.
- Oban: supervised tasks and one deployment lock are enough initially.
- React/Vue/Svelte: an SPA creates a second state model and a new API.
- Ash: too broad for this bounded operator surface.
- Tailwind/Node: unnecessary Nix asset-build complexity for the first UI.
- Raw Cowboy handlers: too low-level for security-sensitive browser sessions.

### Does a WebUI break the project idea?

**No, provided it remains an optional operator presentation layer.** The WebUI is not a leader. Agents continue membership, placement, reconciliation, and systemd control when the WebUI is offline.

It would break the design if it became the desired-state database, directly controlled services outside Nix, exposed arbitrary RPC or the BEAM cookie, ran HTTP on every agent, or made cluster convergence depend on WebUI availability.

### Qualification on removing the CLI

Remove the **user-facing operator CLI** and its escript. Preserve `nix-swarm-query` (or an equivalent noninteractive helper): it is the restricted SSH transport, not a competing user interface. Removing it would push the WebUI toward direct distributed Erlang access or HTTP on agents, weakening the security model.

Keep an emergency headless deployment entry point until the WebUI passes real staging apply/rollback/recovery tests. Delete it only at the final parity gate.

---

## Current context

- `lib/nix_swarm/tui.ex`: 5,591 lines; dashboard, topology, machines, services, logs, filters, export, and update confirmation.
- `lib/nix_swarm/cli.ex`: 656 lines; ensure, init, doctor, plan, apply, rollback, credentials, upgrade, status, members, rebuild, service scaffolding, and logs.
- `NixSwarm.QueryServer`: bounded read-only Unix-socket protocol.
- `NixSwarm.Remote`: hardened SSH access to that protocol, with an explicit read allowlist.
- `NixSwarm.Deploy`, `Update`, `Credentials`, `Cluster.Ensure`, and `ConfigFiles`: reusable non-presentation behavior.
- `nix/nix-swarm/packages.nix`: operator/cluster/combined packages plus the Ratatui NIF cache.
- `nix/nix-swarm/module.nix`: hardened unprivileged agent and restricted query helper; it must not gain browser-facing HTTP.

### Invariants to preserve

1. Nix is the only desired-state model and deployment history.
2. systemd owns service lifecycle, readiness, resources, and logs.
3. agents stay leaderless and unprivileged.
4. read operations use the bounded query protocol.
5. mutations evaluate and deploy complete NixOS closures with health gates.
6. operators never receive the BEAM cookie.
7. SSH host-key verification remains enabled.
8. runtime API service/machine mutators remain absent.
9. logs and labels are untrusted and escaped/sanitized.
10. WebUI downtime never affects convergence.

---

## Target components

### Agent release (`nix-swarmd`)

Keep membership, placement, reconciliation, autoscaling, DETS observations, local systemd execution, `QueryServer`, and `nix-swarm-query`. Add no Phoenix, Bandit, HTTP, WebSockets, browser sessions, or deployment UI.

### Web release (`nix-swarm-web`)

Own browser endpoint, authentication, a shared cluster monitor, cached snapshots, PubSub, plan display, confirmed deployment jobs, source-tree scaffolding with diff preview, and structured audit events.

It must not own desired state outside the Nix checkout, placement, process lifecycle, BEAM membership, agent credentials, or a deployment-history database.

### Presentation-neutral context

Create `lib/nix_swarm/operator.ex` with data-returning APIs such as:

```elixir
defmodule NixSwarm.Operator do
  @spec overview(keyword()) :: {:ok, map()} | {:error, term()}
  @spec members(keyword()) :: {:ok, map()} | {:error, term()}
  @spec logs(String.t(), pos_integer(), keyword()) :: {:ok, list()} | {:error, term()}
  @spec doctor(keyword()) :: {:ok, map()} | {:error, term()}
  @spec deployment_plan(keyword()) :: {:ok, map()} | {:error, term()}
  @spec apply(keyword()) :: {:ok, map()} | {:error, term()}
  @spec rollback(keyword()) :: {:ok, map()} | {:error, term()}
end
```

It must never print, halt, read browser sessions, or render HTML.

---

## Feature parity matrix

| Current behavior | WebUI destination | Boundary |
| --- | --- | --- |
| Dashboard | `/` | Read-only query |
| Topology | `/topology` | Read-only query |
| Machines | `/machines` | Read-only query |
| Services | `/services` | Read-only query |
| Service/machine/cluster logs | `/logs` | Bounded read-only query |
| Members/status | Dashboard and machines | Read-only query |
| Doctor | `/diagnostics` | SSH/query diagnostics |
| Deployment plan | `/deploy` | Nix evaluation only |
| Apply/upgrade | `/deploy` confirmed job | Existing Nix deployment boundary |
| Rollback | `/deploy/history` | Native NixOS rollback |
| Credentials/init/ensure | `/setup` | Existing modules |
| Service template list | `/source/services/new` | Read-only templates |
| Service create/add | Diff preview and confirmed file create | Code checkout only |
| JSON CLI output | No first-version replacement | Avoid accidental API scope |
| Debug state | Remains unavailable | Security boundary |
| Log export | Authenticated bounded download | Escaped text |

Do not delete the old interfaces until every retained row has an acceptance test or an explicit decision to drop it.

---

## Implementation tasks

### Task 1: Freeze architecture and security contracts

**Files:**
- Create: `docs/WEBUI_ARCHITECTURE.md`
- Modify: `AGENT.md`
- Test: `test/nix_swarm_project_policy_test.exs`

**Steps:**
1. Add failing policy tests proving the agent children contain no web endpoint and runtime mutations remain absent.
2. Document loopback default, no-cookie, no-agent-HTTP, Nix-only state, and optional WebUI behavior.
3. Update contributor rules.
4. Run `nix develop --command mix test test/nix_swarm_project_policy_test.exs`.
5. Commit: `docs: define web operator trust boundary`.

### Task 2: Extract `NixSwarm.Operator`

**Files:**
- Create: `lib/nix_swarm/operator.ex`
- Create: `test/nix_swarm_operator_test.exs`
- Modify temporarily: `lib/nix_swarm/cli.ex`, `lib/nix_swarm/tui.ex`

**Steps:**
1. Write failing tests for overview, members, bounded logs, doctor, plan, apply, and rollback with injected dependencies.
2. Implement a thin façade over `Remote`, `Deploy`, `Update`, `Credentials`, `Cluster.Ensure`, and `ConfigFiles`.
3. Normalize all results to `{:ok, value}` or `{:error, reason}`.
4. Refactor terminal interfaces to use it temporarily.
5. Run operator, CLI, and TUI tests.
6. Commit: `refactor: extract operator context from terminal interfaces`.

### Task 3: Create a separate Phoenix application

**Files:**
- Create: `web/mix.exs`, `web/mix.lock`
- Create: `web/config/{config,dev,test,runtime}.exs`
- Create: `web/lib/nix_swarm_web/{application,endpoint,router}.ex`
- Create: `web/lib/nix_swarm_web.ex`
- Create: `web/test/support/conn_case.ex`
- Create: `web/test/test_helper.exs`
- Create: `web/test/nix_swarm_web/smoke_test.exs`

**Dependencies:**

```elixir
[
  {:nix_swarm, path: ".."},
  {:phoenix, "~> 1.8"},
  {:phoenix_live_view, "~> 1.2"},
  {:phoenix_html, "~> 4.0"},
  {:bandit, "~> 1.12"}
]
```

Do not add Ecto. Run the root dependency in operator role.

**Steps:**
1. Write a failing `GET /healthz` test.
2. Create the minimal endpoint and Bandit listener.
3. Add a root LiveView placeholder.
4. Assert WebUI startup does not start Cluster, Reconciler, QueryServer, or distributed Erlang.
5. Commit: `feat(web): add separate Phoenix operator application`.

### Task 4: Add authentication and safe defaults

**Files:**
- Create: `web/lib/nix_swarm_web/auth.ex`
- Create: `web/lib/nix_swarm_web/live_auth.ex`
- Create session controller/templates and tests
- Modify: router and runtime config

**Rules:**
- Bind `127.0.0.1` by default.
- Load login token and `SECRET_KEY_BASE` through files/systemd credentials, never the store.
- Use encrypted/signed `HttpOnly`, `SameSite=Strict` sessions with expiry.
- Enforce CSRF and LiveView `check_origin`.
- Refuse wildcard binding without explicit secure mode.
- Never expose SSH/key material in assigns.

**Tests:** unauthenticated HTTP/socket rejection, valid/invalid token, logout, expiry, wildcard-bind refusal, CSRF.

**Commit:** `feat(web): secure operator sessions and loopback binding`.

### Task 5: Add one shared cluster monitor

**Files:**
- Create: `web/lib/nix_swarm_web/operator/cluster_monitor.ex`
- Create: `web/lib/nix_swarm_web/operator/target.ex`
- Create tests
- Modify Web application supervisor

**Behavior:** poll one configured target through `Operator.overview/1`, cache last success/error/timestamp/latency, broadcast through PubSub, use bounded interval and backoff, and mark stale data. Never perform SSH directly in a LiveView process or once per browser.

**Commit:** `feat(web): cache and broadcast cluster snapshots`.

### Task 6: Build dashboard and topology

**Files:**
- Create: `dashboard_live.ex`, `topology_live.ex`
- Create core and cluster components
- Create plain CSS
- Create LiveView tests

Port semantic assertions, not terminal layout. Render health, target, generation/config consistency, stale status, members, services, owners, replicas, issues, and versions. Use semantic HTML/SVG/CSS and escape all values.

**Commit:** `feat(web): add cluster dashboard and topology`.

### Task 7: Build machines and services views

Create `machines_live.ex`, `services_live.ex`, and tests for running/stopped/restarting/failed/missing/stale/mixed-version/config-mismatch states. Keep selection/filter state URL-addressable. Keep these views read-only.

**Commit:** `feat(web): add machine and service views`.

### Task 8: Build bounded logs and export

**Files:**
- Create: `logs_live.ex`
- Create: authenticated `log_export_controller.ex`
- Create tests

Use `NixSwarm.Operator` only. Preserve bounds `1..1000`, control-sequence sanitation, HTML escaping, safe filenames, and bounded downloads. Do not implement unbounded tail streaming; refresh bounded windows.

**Commit:** `feat(web): add bounded log inspection and export`.

### Task 9: Add supervised deployment planning

**Files:**
- Create: `deployment_supervisor.ex`, `deployment_job.ex`, `deploy_live.ex`
- Create job and LiveView tests

Start with plan/dry-run only. Run jobs under supervision, not LiveView. Show source, flake, target configurations, deploy hosts, closures, canaries, batches, health policy, and rollback policy. Restrict sources to the configured root. Test timeouts, crashes, reconnects, and duplicate submissions.

**Commit:** `feat(web): add supervised deployment planning`.

### Task 10: Add confirmed mutations

Extend deployment jobs for apply, upgrade, rollback, ensure/init, and credentials.

**Rules:**
- Mutation disabled by default.
- Require a fresh authenticated session and typed operation/target confirmation.
- Recompute the plan server-side immediately before apply.
- Reject arbitrary source paths, shell fragments, Nix expressions, SSH options, and executable paths.
- Log operation, source revision, targets, duration, and result to journald without secrets.
- Keep native rollback and health gates.
- Jobs survive browser disconnects under supervision.

**Commit:** `feat(web): add confirmed code-first deployment actions`.

### Task 11: Add service scaffolding with diff preview

**Files:**
- Create: `web/lib/nix_swarm_web/source_workspace.ex`
- Create: `service_new_live.ex` and tests

List templates, validate with existing modules, generate content in memory, show exact diff, require confirmation, use exclusive file create, never overwrite, never silently edit `cluster.nix`, and display dirty Git state.

**Commit:** `feat(web): scaffold Nix service files with diff review`.

### Task 12: Package WebUI independently

**Files:**
- Create: `nix/nix-swarm/web-package.nix`
- Create: `nix/nix-swarm/web-module.nix`
- Modify: `nix/nix-swarm/packages.nix`, `flake.nix`, `flake.lock`

**Target outputs:**

```text
packages.x86_64-linux.cluster
packages.x86_64-linux.webui
nixosModules.default
nixosModules.webui
apps.x86_64-linux.webui
```

NixOS defaults: separate user, loopback listener, credential loading, scoped checkout write access only when enabled, read-only mode by default, no cookie, hardened systemd, strict known-host checking, no firewall opening.

Add VM tests proving authentication, loopback binding, no cookie, read-only dashboard, and agent closure exclusion of Phoenix/LiveView/Ratatui.

**Commit:** `build: package isolated WebUI operator release`.

### Task 13: Parity/deprecation release

Update README, operations, security, testing, changelog, and getting-started docs. Ship one release with WebUI preferred and CLI/TUI deprecated. Test dashboard, logs, plan, failed deployment, rollback, WebUI restart during a job, and agent outage. Confirm agents converge while WebUI is down.

Document access through a tunnel:

```bash
ssh -L 4000:127.0.0.1:4000 operator-host
```

Inventory external JSON CLI automation before deletion.

**Commit:** `docs: make WebUI the primary operator interface`.

### Task 14: Remove Ratatui TUI

**Delete:**
- `lib/nix_swarm/tui.ex`
- `test/nix_swarm_tui_test.exs`

**Modify:** `mix.exs`, `mix.lock`, Nix packages, policy tests, docs.

Port semantic tests first, remove `ex_ratatui`, remove NIF fetches/hashes/runtime checks, and prove the NIF is absent from closures.

**Commit:** `refactor: remove Ratatui operator interface`.

### Task 15: Remove user-facing CLI and escript

**Delete:**
- `lib/nix_swarm/cli.ex`
- `test/nix_swarm_cli_test.exs`

**Modify:**
- `mix.exs`: remove escript entrypoint
- `nix/nix-swarm/packages.nix`: remove operator wrapper/combined package/starter auto-copy
- `flake.nix`: remove CLI apps and smoke checks
- docs/tests

**Preserve:** `query_cli.ex`, `query_client.ex`, and cluster package `nix-swarm-query` helper.

Delete only after every retained CLI operation has WebUI parity or an explicit drop decision.

**Commit:** `refactor: replace operator CLI with WebUI`.

### Task 16: Full release verification

```bash
nix develop --command bash -c '
  mix deps.get &&
  mix format --check-formatted &&
  mix clean &&
  mix compile --warnings-as-errors &&
  mix hex.audit &&
  mix test --warnings-as-errors --cover
'

cd web
nix develop .. --command bash -c '
  mix deps.get &&
  mix format --check-formatted &&
  mix clean &&
  mix compile --warnings-as-errors &&
  mix hex.audit &&
  mix test --warnings-as-errors
'

cd ..
nix flake check --print-build-logs
nix build .#checks.x86_64-linux.nixos-vm --no-link --print-build-logs
nix build .#checks.x86_64-linux.webui-vm --no-link --print-build-logs
MIX_ENV=test nix develop --command mix run --no-start scripts/verify_cluster.exs
./scripts/docker-stack up
./scripts/docker-stack status
```

Manual gates:

1. Loopback-only default and wildcard refusal.
2. HTTP and LiveView authentication.
3. Status/logs through SSH/query socket.
4. Plan is non-mutating.
5. Apply recomputes plan and requires typed confirmation.
6. Failed rollout uses existing rollback.
7. WebUI restart does not alter agent placement.
8. Agents converge with WebUI stopped.
9. No cookie in WebUI or agent argv/environment.
10. Agent closure excludes web dependencies.
11. Web closure excludes Ratatui.
12. Malicious log/label content is escaped.
13. No generated assets, credentials, or Nix results enter Git.

Do not remove the emergency headless deployment path until real staging apply and rollback succeed through the WebUI.

---

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| WebUI becomes de facto leader | Keep placement/reconciliation entirely on agents; WebUI remains optional. |
| Browser attack surface | Separate user/process/package, loopback, auth, CSRF/origin, no agent HTTP/cookie, bounded operations. |
| SSH load per browser | One cached cluster monitor plus PubSub. |
| Browser-only recovery/automation gap | Parity period and temporary emergency headless path. |
| UI undermines code-first model | Diff preview, checkout-only writes, exclusive creates, no DB, Nix closure deployment only. |
| Deployment outlives socket | Supervised jobs with operation IDs and reconnectable PubSub state. |
| Phoenix bloats agents | Separate Mix release/Nix package and closure tests. |
| Asset reproducibility | Minimal prebuilt assets; no Node/Tailwind initially. |
| JSON CLI users break | Inventory usage; add a separately designed narrow API only if required. |

---

## Open product decisions

1. WebUI host: dedicated operator host/workstation is recommended, never every agent.
2. First release: read-only dashboard/logs first is recommended.
3. Browser editing: template scaffolding/diff only; arbitrary Nix editing is out of scope.
4. Automation: identify whether external scripts require the JSON CLI before removal.
5. Authentication: localhost + SSH tunnel + token session for v1; reverse-proxy OIDC later.
6. Multiple clusters: one source/target in v1; multi-cluster later with explicit isolation.
7. Durable job history: use Nix generations and journal audit events, not a new database.
8. Mutation mode: configurable and disabled by default.

---

## Suggested releases

1. **Release A:** operator context plus authenticated read-only dashboard/logs; CLI/TUI remain.
2. **Release B:** supervised plan/apply/rollback/setup; WebUI preferred, terminal interfaces deprecated.
3. **Release C:** staging hardening, VM/recovery tests, optional source scaffolding.
4. **Release D:** remove Ratatui and user-facing CLI after parity sign-off; retain restricted query helper.

This avoids a big-bang rewrite and gives the project a rollback point after every layer.
