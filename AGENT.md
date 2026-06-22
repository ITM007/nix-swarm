# Nix-Swarm agent handbook

## Outline

1. **Project purpose** — leaderless Elixir/OTP orchestrator for small NixOS clusters
2. **Model** — Nix defines state, every node runs same runtime, deterministic placement, systemd units only
3. **Implementation status** — OTP app, TUI, placement, reconciler, systemd/fake executors, CLI, bootstrap, deploy, update, ingress, Nix packages
4. **Scope boundaries** — v1 stateless only, Nix is truth, leaderless, eventually consistent, no stateful HA
5. **Architecture: top-level flow** — Nix renders config → OTP app → Cluster connects → Placement computes → Reconciler converges → API exposes → Remote RPC → CLI/TUI
6. **Architecture: invariants** — only configured peers, deterministic local placement, periodic idempotent reconciliation, executor adapter, replica spreading
7. `NixSwarm.Application` — supervision tree (Cluster, Reconciler)
8. `NixSwarm.Config` — runtime config loader, Erlang terms format, normalize into peers/nodes/services/runtime
9. `NixSwarm.Service` — replica normalization, constraints, unit templates, slot enumeration
10. `NixSwarm.Cluster` — peer connectivity loop, live peer set, ignore non-cluster nodes
11. `NixSwarm.Placement` — deterministic ownership, stable hash ranking, slot cycling, replica spreading
12. `NixSwarm.Reconciler` — periodic convergence, start owned / stop unowned, service modes, healthcheck execution
13. `NixSwarm.Executor` — adapter abstraction, validate_unit_name, dispatch to Systemd or Fake
14. `NixSwarm.Executor.Systemd` — systemctl start/stop/restart, journalctl logs, metrics via systemd properties
15. `NixSwarm.Executor.Fake` — file-backed executor for tests, sanitize_node_name
16. `NixSwarm.API` — public RPC surface: local_status, cluster_status, cluster_members, cluster_overview, reconcile, service actions, logs, metrics, network_info, ingress_info
17. `NixSwarm.CLI` — escript entrypoint, --version, --target, --cookie-file, cluster ensure subcommand
18. `NixSwarm.TUI` — ex_ratatui dashboard (~172KB): Dashboard, Map, Machines, Services, Logs, Rollout, Edit views
19. `NixSwarm.Remote` — distributed Erlang RPC, connect!/diagnose, port checks, cookie resolution, distribution_port
20. `NixSwarm.ConfigFiles` — Nix config I/O, add/delete machine/service, cluster topology editing
21. `NixSwarm.Paths` — operator working tree resolution (~/.config/nix-swarm/)
22. `NixSwarm.NodeName` — node name validation, cookie_atom!, safe_string_to_atom, control_node?
23. `NixSwarm.Update` — version-aware rollout, wait_for_cluster_state convergence, rollout_report_ready?
24. `NixSwarm.ClusterLogs` — remote log tail helper
25. `NixSwarm.ASCII` — cluster topology ASCII art
26. `NixSwarm.Bootstrap` — machine module generator, NixOS file generation
27. `NixSwarm.Deploy` — SSH sync + rebuild, dry-run, shell_escape, validation
28. `NixSwarm.Cluster.Ensure` — declarative bootstrap: reads cluster.nix, SSHes to deployHosts, checks swarmd, creates flake/config, syncs source, copies cookie, rebuilds
29. **Files & directories** — mix.exs, lib/, test/, nix/, cluster/, machines/, examples/
30. **Testing workflow** — mix format, mix test, mix escript.build, mix run scripts/verify_cluster.exs
31. **Deployment model** — NixOS module, operator/cluster packages, SSH transport, DNS not managed
32. **Guidance: placement/cluster changes** — re-run tests + verify_cluster
33. **Guidance: config/Nix changes** — keep Config, module.nix, cluster.nix, services/*.nix, README aligned
34. **Guidance: adding features** — keep behavior local to owning module
35. **Guidance: complexity** — keep it simple, leaderless, Nix as truth, no stateful storage creep
36. **TUI: status bar** — version display, target, refresh time, data freshness, idle/loading throbber
37. **TUI: auto-refresh** — 30s default (--refresh-ms), silent background refresh (no throbber)
38. **TUI: mouse scroll** — all containers (tables, summaries, logs, filters)
39. **TUI: rollout/update** — u key, cluster or selected-machine scope, enter to confirm
40. **Cookie model** — shared Erlang cookie, NIX_SWARM_COOKIE_FILE env, base64 support since v0.4.1
41. **Distribution ports** — epmd 4369, dist 4370 (configurable via distributionPort)
42. **Firewall** — openFirewall option, firewallInterfaces, operator needs 4369+4370 open for bidirectional
43. **ELIXIR_ERL_OPTIONS** — sets dist port on operator; Nix wrapper in packages.nix
44. **Ingress** — nginx helper in ingress.nix, httpPort configurable (default 80)
45. **Healthcheck** — per-service shell command, run during reconciliation, results in local_status
46. **Version** — VERSION file (single source), Application.spec, @fallback_version, release_label
47. **RPC timeout** — NixSwarm.rpc_timeout_ms/0 (5000ms default), used in 5 call sites
48. **Shared helpers** — NixSwarm.nix_string_literal/1, NixSwarm.fetch_value/3, sanitize_node_name/1
49. **Changelog** — v0.4.1: cookie chain fix, dist port, base64 cookies, cluster ensure; v0.4.0: healthcheck, ingress, hardening
50. **Notes** — quick observations, gotchas, reminders

---

## Project purpose

Nix-Swarm is a leaderless Elixir/OTP orchestrator for small NixOS clusters.

The intended model is:

- Nix defines the desired cluster state
- every machine runs the same long-lived Nix-Swarm runtime
- each node computes service ownership from the shared config plus current live peers
- each node only starts/stops local systemd units
- operators use a CLI to connect to any reachable node for status and operational actions

This project is intentionally **not** a container platform and **not** a consensus-based scheduler. v1 is small on purpose.

## Current implementation status

The Rust scaffold has already been replaced with a working Elixir/OTP implementation.

Implemented today:

- OTP application with peer connectivity and periodic reconciliation
- deterministic placement with replica spreading across eligible nodes
- systemd executor for real hosts
- fake executor for tests and local verification
- full terminal UI (`NixSwarm.TUI`) with dashboard, topology map, machines, services, logs, rollout, dry-run, apply, and in-TUI config editing (largest module, ~172KB)
- CLI entrypoint (`NixSwarm.CLI`) built as an escript; primarily launches the TUI
- config-files subsystem (`NixSwarm.ConfigFiles`) for declarative Nix config reading/writing/validation from the TUI
- remote RPC layer (`NixSwarm.Remote`) encapsulating all distributed Erlang calls to target nodes
- machine bootstrap helper (`NixSwarm.Bootstrap`) for generating NixOS host modules and optional deploys
- deploy helper (`NixSwarm.Deploy`) for validating and syncing declarative cluster changes to hosts over SSH
- declarative cluster bootstrapper (`NixSwarm.Cluster.Ensure`) — `swarm cluster ensure`
- update subsystem (`NixSwarm.Update`) for version-aware rollout tracking
- ASCII cluster topology map (`NixSwarm.ASCII`)
- user-edited cluster layout under `cluster/` plus machine stubs under `machines/`
- internal NixOS module/package files under `nix/nix-swarm/`
- small built-in ingress helper under `nix/nix-swarm/ingress.nix`
- Nix package and flake entrypoints (`default.nix`, `nix/nix-swarm/package.nix`, `flake.nix`)
- operator and cluster package split: `swarm` CLI for operators, `nix-swarmd` for managed nodes
- three-node integration test
- three-node manual verification script

## Scope boundaries

Treat these as hard constraints unless the user explicitly changes them:

- v1 is for **stateless** or **externally-backed** services only
- Nix remains the source of truth for desired state
- the CLI is not the source of truth for service definitions
- the cluster is leaderless and eventually consistent
- temporary duplicate instances during partitions are acceptable in v1
- stateful HA storage/database orchestration is out of scope

## Architecture overview

### Top-level flow

1. Nix renders a `nix-swarm.config` Erlang terms file for each machine.
2. The node runs the same `:nix_swarm` OTP application.
3. `NixSwarm.Cluster` connects configured peers and tracks the live membership view.
4. `NixSwarm.Placement` computes service-slot ownership deterministically from:
   - service definition
   - live configured peers
   - node labels / constraints
5. `NixSwarm.Reconciler` starts owned units and stops unowned units on the local machine.
6. `NixSwarm.API` exposes status/restart/log/reconcile operations for remote callers.
7. `NixSwarm.Remote` is the RPC layer — all distributed Erlang calls from CLI/TUI to target nodes go through it.
8. `NixSwarm.CLI` starts a distributed Erlang node and launches `NixSwarm.TUI` (the operator dashboard) by default.

### Important invariants

- only **configured peers** participate in placement; arbitrary connected nodes must not affect scheduling
- placement is deterministic and local; there is no central assigner
- reconciliation is periodic and idempotent
- local execution happens through an executor adapter
- service ownership should spread replicas across eligible nodes before reusing a node
- partitions may cause temporary over-replication because the system is leaderless

## Module guide

### `NixSwarm.Application`

Starts the runtime supervision tree.

Current children:

- `NixSwarm.Cluster`
- `NixSwarm.Reconciler`

### `NixSwarm.Config`

Runtime config loader and normalizer.

Config sources:

- `Application.get_env(:nix_swarm, :cluster_config)` for tests/dev
- `NIX_SWARM_CONFIG_PATH` / app env `:config_path` for rendered config files

Config format:

- Erlang terms file, not JSON/TOML
- normalized into:
  - `peers`
  - `nodes`
  - `services`
  - `runtime`
  - `ingress`

### `NixSwarm.Service`

Service-spec normalization helpers.

Encapsulates:

- replica count normalization
- constraint handling
- unit template rendering
- slot enumeration
- healthcheck preservation

### `NixSwarm.Cluster`

Peer connectivity loop.

Responsibilities:

- periodically attempt `Node.connect/1` to configured peers
- expose the live configured peer set
- ignore non-cluster nodes for placement

### `NixSwarm.Placement`

Deterministic ownership logic.

Current strategy:

- rank eligible nodes per service using a stable hash
- cycle service slots across that ranking
- if there are more replicas than eligible nodes, ownership wraps around

### `NixSwarm.Reconciler`

Periodic local convergence loop.

Responsibilities:

- compute desired local ownership
- ensure owned units are running
- ensure unowned units are stopped
- provide local status and restart helpers
- run per-service healthchecks during reconciliation

### `NixSwarm.Executor`

Executor abstraction with `@spec` on all functions.

Adapters:

- `NixSwarm.Executor.Systemd`
- `NixSwarm.Executor.Fake`

### `NixSwarm.API`

Remote node-facing API with `@doc` on all 18 public functions.

Current operations:

- cluster status, members, overview
- reconcile, restart service, start/stop on node
- logs, cluster logs, node service logs
- metrics, network info, ingress info

### `NixSwarm.CLI`

Human/operator entrypoint.

Commands:

- `swarm` — launches TUI
- `swarm --version` — prints version
- `swarm cluster ensure` — bootstraps all machines in cluster.nix
- `--target`, `--cookie-file`, `--name`, `--refresh-ms`, `--source`, path overrides

### `NixSwarm.TUI`

Full-screen terminal operator dashboard built with `ex_ratatui` (~172 KB).

Tabs/views:

- Dashboard — cluster overview, version matrix, metrics, health
- Map — ASCII topology map
- Machines — per-machine status, restart, logs
- Services — per-service status, placement diagnostics
- Logs — live log tail
- Rollout — dry-run/apply/update workflows
- Edit — config editing via $EDITOR

### `NixSwarm.Remote`

Distributed Erlang RPC layer.

Encapsulates:

- node connection/discovery, doctor diagnostics
- cookie resolution, port checks, distribution_port
- legacy Swarm.API fallback for old releases

### `NixSwarm.ConfigFiles`

Declarative Nix config reader/writer/validator.

### `NixSwarm.Paths`

Central path resolution (`~/.config/nix-swarm/`).

### `NixSwarm.NodeName`

Node name validation, cookie_atom! with base64 support, safe_string_to_atom.

### `NixSwarm.Update`

Version-aware rollout tracking with convergence timeout handling.

### `NixSwarm.ClusterLogs`

Remote log tail helper.

### `NixSwarm.ASCII`

ASCII cluster topology map.

### `NixSwarm.Bootstrap`

Machine module generator for NixOS host files.

### `NixSwarm.Deploy`

SSH sync + rebuild with validation, dry-run, shell escaping.

### `NixSwarm.Cluster.Ensure`

Declarative bootstrap: `swarm cluster ensure` reads cluster.nix, SSHes to each deployHost, checks swarmd, bootstraps if needed.

## Files and directories

- `mix.exs` — project definition, escript entrypoint, ex_ratatui dep
- `VERSION` — single source of truth for release version
- `default.nix` / `flake.nix` / `nix/nix-swarm/packages.nix` — Nix packaging
- `lib/nix_swarm.ex` — root module, helpers (nix_string_literal, fetch_value, rpc_timeout_ms)
- `lib/nix_swarm/application.ex` — OTP supervision tree
- `lib/nix_swarm/tui.ex` — terminal dashboard (~172 KB)
- `lib/nix_swarm/cluster/ensure.ex` — declarative cluster bootstrapper
- `lib/nix_swarm/api.ex` — node-facing API (18 public functions)
- `lib/nix_swarm/remote.ex` — distributed Erlang RPC
- `lib/nix_swarm/placement.ex` — deterministic ownership
- `lib/nix_swarm/reconciler.ex` — convergence loop + healthcheck
- `lib/nix_swarm/deploy.ex` — SSH rollout
- `lib/nix_swarm/config_files.ex` — Nix config I/O
- `lib/nix_swarm/executor/` — systemd and fake adapters
- `lib/nix_swarm/node_name.ex` — node naming + cookie validation
- `test/` — 139 tests (API, Placement, Reconciler, Executor, CLI, Remote, NodeName)
- `scripts/verify_cluster.exs` — three-node manual verification
- `cluster/` — user-edited cluster topology
- `nix/nix-swarm/module.nix` — NixOS integration module
- `nix/nix-swarm/ingress.nix` — nginx ingress helper

## Testing and verification

```bash
mix format --check-formatted
mix test                          # 139 tests
mix escript.build
mix run scripts/verify_cluster.exs
```

## Deployment model

- NixOS module at `nix/nix-swarm/module.nix`
- Operator package: `swarm` CLI + TUI
- Cluster package: `nix-swarmd` runtime
- Bootstrap: `swarm cluster ensure` reads cluster.nix, SSHes, sets up, rebuilds
- Cookie: shared via `NIX_SWARM_COOKIE_FILE`, base64 supported (v0.4.1+)
- Distribution port: 4370 fixed via ELIXIR_ERL_OPTIONS or ERL_AFLAGS
- Firewall: epmd 4369 + dist 4370 on both operator and managed nodes

## Guidance for future agents

### When editing placement or cluster behavior

Re-run `mix test` and `mix run scripts/verify_cluster.exs`.

### When editing config or Nix integration

Keep aligned: Config, module.nix, cluster.nix, services/*.nix, README.md.

### When adding features

Keep behavior local: config→Config, placement→Placement, execution→Executor, API→API, RPC→Remote, TUI→TUI, config I/O→ConfigFiles, bootstrap→Cluster.Ensure.

### When tempted to add complexity

- keep it simple, leaderless, Nix as truth
- do not expand into stateful storage orchestration
- call out changes toward consensus or mutable control-plane state

## Notes

<!-- Add quick observations, gotchas, or reminders here. -->
