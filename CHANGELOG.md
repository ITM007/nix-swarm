# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- A restricted SSH-to-local-Unix-socket operator API; operator tools no longer join the BEAM cluster or receive its cookie.
- One-command credential enrollment and health-gated flake-input upgrades.
- A minimal packaged starter flake, flake apps, bounded query protocol, and security regression tests.
- Declarative service capacity controls, readiness gates, per-node replica limits, and bounded CPU autoscaling with hysteresis.

- Agent/operator-specific supervision trees with supervised task execution.
- A validated, fail-closed ETS configuration snapshot owner and configuration digests.
- A DETS-backed operational-state store for the last Nix generation, assignments, health, and reconciliation result.
- `:erpc`-based bounded RPC helpers and telemetry spans for reconcile, RPC, command, and deploy work.
- Native NixOS rollout batches, canary ordering, and `nixosConfiguration` node metadata.
- Flake checks for both packages and a complete NixOS module evaluation, plus CI gates.
- Optional ACME/forced-SSL ingress configuration.
- Elixir 1.20 set-theoretic signature inference in application and test compilation.
- Coverage-gated tests for secrets, rollout logic, RPC, the fake executor, watchdog notifications, templates, and deployment compatibility entry points.
- Code-first `cluster plan`, `cluster apply`, `cluster rollback`, and `cluster doctor` workflows.
- Declarative `active`/`draining` node availability and native systemd `OnFailure=` integration.
- Operator query commands for cluster overview, membership, snapshots, and bounded service logs over the restricted socket API.
- v1.0 migration and release-gate documentation, including the supported stateless-workload boundary and partition behavior.
- Packaged operator smoke coverage for help, version, and deployment-plan entry points on x86_64 Linux.
- A three-node x86_64 NixOS/Docker Compose integration harness with systemd-managed demo workloads, SSH query access, persistent node state, and documented node failure/rejoin exercises.
- A packaged starter configuration with a minimal flake, example machine, service, and hardware stubs for new deployments.
- Release, migration, parity, operations, security, Docker, and development documentation covering the hardened v1.0 readiness path.

### Changed

- Release artifacts now run the full BEAM/Nix validation gate and reject tags
  that do not match `VERSION`.
- Direct API log requests clamp line counts and use the executor timeout path
  for `nix-swarmd` logs instead of invoking `journalctl` without a command
  timeout.
- The agent runs unprivileged with an exact Nix-generated polkit unit allowlist and systemd resource limits.
- Release cookies are provisioned as private runtime files and no longer appear in process arguments or environment variables.
- Intermediate rollout batches require reachable peers and healthy updated-node units; the final gate requires one config digest and all owned units healthy.
- Source packaging is allowlisted, log output is terminal-sanitized, and ex_ratatui is updated to 0.11.1.

- Deployments now evaluate local `nixosConfigurations` and use `nixos-rebuild --target-host`; remote source copying and remote Nix-file generation are gone.
- SSH uses the normal client configuration with strict host-key checking.
- Reconciliation reacts immediately to node membership changes and batches systemd status reads.
- Placement uses SHA-256 scoring rather than VM-dependent term hashing.
- Health is derived from systemd unit state; arbitrary shell health checks are no longer executed by the root agent.
- `nix-swarmd` now has explicit watchdog, stop, restart-backoff, state-directory, and systemd sandbox lifecycle settings.
- Version metadata is read from `VERSION` by both Mix and Nix.
- CI now compiles test modules with type inference and warnings-as-errors and enforces the coverage baseline.
- The operator TUI is read-only; all durable changes flow through reviewed Nix code and explicit CLI deployment commands.
- Runtime desired-state overrides were replaced by durable, node-local operational observations.
- Configuration loading now has a supervised ETS snapshot owner, generation/digest tracking, and explicit runtime validation.
- Deployment and upgrade workflows preserve flake locks on failure, support native NixOS configuration selection, and report rollout convergence by node.
- Credential enrollment is idempotent for matching remote fingerprints, installs only missing hosts, and performs coordinated cookie rotation with restart, health verification, and rollback of the previous credential.
- Packaged operator and query wrappers now start the application supervision tree before evaluating CLI commands; help and version handling avoids deployment-source side effects.
- Deployment manifests are exported under the standard `lib.nixSwarm.deploymentManifest` flake output, and CI evaluates the complete flake checks on x86_64 Linux.
- Release checks now target x86_64 Linux only; the NixOS VM test exercises systemd watchdog survival, the restricted query helper, and durable agent state.
- Public README, contributing, security, getting-started, and configuration-reference docs now describe the code-reviewed deployment model and x86_64-only support boundary.

### Removed

- Unsafe automatic file-watcher deployment and its standalone systemd unit.
- The executor GenServer that bypassed the validated fake/systemd adapter boundary.
- SSH bootstrap code that wrote placeholder machine files and secrets on targets.
- Remote API endpoints for ad-hoc service and machine mutation.

### Fixed

- Autoscaler target reconstruction now drops decisions for services removed
  from the current configuration instead of retaining stale targets.
- Restored the rollout coordinator and injected TUI update function removed by the v0.5 work-in-progress.
- Restored executor input validation, configured adapters, command timeouts, and normalized status contracts.
- Invalid deployment validation now aborts before any target is changed.
- Cluster status reports configuration digest drift across live nodes.
- Age encryption no longer passes an unsupported stdin option to `System.cmd/3`, and temporary plaintext input is mode `0600` and removed after encryption.
- Generated web and custom NixOS service templates correctly bind their `pkgs` argument.
- Reconciler tests restore application state and are no longer order-dependent.
- Credential rotation restores the local cookie when coordinated remote rotation fails, and SSH preflight distinguishes a missing credential from an unreachable host.
- Packaged deployment commands no longer crash because `NixSwarm.TaskSupervisor` was not started.
- The systemd watchdog now sends the supported `WATCHDOG=1` notification, and local operator queries handle dynamic node atoms safely.
- Packaged SSH query helpers now preload the safe response atoms and keep machine-readable output free of runtime startup noise.
- Packaged query helpers now terminate their machine-readable response before runtime shutdown diagnostics can append to it.
- The packaged operator launcher now loads the restricted-query protocol before safe response decoding.
- Cluster status output no longer duplicates the `v` prefix in node release labels.
- The Docker demo workload now uses a fixed per-node HTTP port so all published node ports are directly testable.
- Autoscaler sample aggregation, target clamping, membership invalidation, and stale-decision rejection have deterministic coverage.

## [0.4.1] - 2026-06-18

### Fixed

- **Cookie chain**: `swarmdStart` now exports `NIX_SWARM_COOKIE` (instead of `RELEASE_COOKIE`) so the daemon wrapper's `resolve_cookie` function picks it up correctly. Previously the wrapper generated a random fallback cookie, causing "Invalid challenge reply" on every connection attempt.
- **Operator distribution port**: the `swarm` CLI wrapper now sets `ELIXIR_ERL_OPTIONS` with `-kernel inet_dist_listen_min 4370 -kernel inet_dist_listen_max 4370` so the operator's Erlang node listens on a fixed port that remote peers can connect back to.
- **Cookie regex**: expanded to accept base64 characters (`+`, `/`, `=`) so `openssl rand -base64` output works directly as a cookie value.
- **`:net_kernel.start` call**: reverted to the simple `[Name, Mode]` format after several failed attempts to pass distribution port options inline (the Erlang API varies across OTP versions).
- Cluster config files (`cluster/cluster.nix`, `cluster/services/`) are preserved across source syncs.

### Changed

- Default refresh interval changed from 3s to 30s (user-adjustable via `--refresh-ms`).
- Auto-refresh no longer shows the "auto-refreshing" throbber in the TUI header.
- Version (`release_label`) always visible in the TUI status bar.
- `cookieFile` path accepted in base64-compatible format.

## [0.4.0] - 2026-06-18

### Added

- Healthcheck execution: services with a `healthcheck` command now have it run during each reconciliation cycle. Results (healthy/unhealthy with output) appear in `local_status` and cluster status views.
- Ingress configuration now flows through the NixOS module into the Erlang terms config and is exposed via `NixSwarm.API.ingress_info/0`.
- `--version` CLI flag prints the release label and exits.
- `@spec` type annotations on all public functions in `NixSwarm.Executor` and `NixSwarm.Placement`.
- `@doc` documentation on all 18 public functions in `NixSwarm.API`.
- New test files: `nix_swarm_api_test.exs` (10 tests), `nix_swarm_reconciler_test.exs` (12 tests), plus 6 additional placement tests (total: 137 tests, up from 109).
- `VERSION` file as single source of truth for the release version, read by both Nix and Elixir builds.
- `NixSwarm.rpc_timeout_ms/0` centralizes the RPC timeout (was hardcoded `5_000` in 5 places).
- `NixSwarm.nix_string_literal/1` and `NixSwarm.fetch_value/3` shared helpers extracted from duplicated private copies.
- `NixSwarm.Executor.Fake.sanitize_node_name/1` public function (deduplicated from test support).
- `packages.nix` now accepts `usePrebuiltNifs ? true` for air-gapped/offline NIF builds.
- `services.nix-swarm.ingress.httpPort` option (default 80) replaces hardcoded port in `ingress.nix`.
- `distributionPort` now propagates from NixOS module through `NIX_SWARM_DISTRIBUTION_PORT` env var to `Remote` probe.

### Changed

- `Config.load_from_path/1` returns `{:ok, terms}` / `{:error, reason}` instead of raising on parse errors.
- `Update.wait_for_cluster_state` returns error-tagged map instead of raising on convergence timeout.
- `API.collect_statuses` returns a safe error map for unreachable nodes instead of raw `{:badrpc, _}` tuples.
- `default.nix` now accepts `pkgs` as an argument with `<nixpkgs>` fallback for pure evaluation.
- TUI catch-all `handle_event` now logs unhandled events at debug level.

### Fixed

- Inconsistent `disk` key in `Executor.default_metrics/0` unified to `disk: %{used: 0}` across all three executor modules.
- `persistent_term.put` in `API.version/0` guarded against table-full errors.
- Source path validated for shell metacharacters before use in SSH deploy commands.
- `String.to_atom/1` calls in `NodeName` now prefer `String.to_existing_atom/1` to reduce atom table exhaustion risk.

### Removed

- Dead code: `Remote.with_connection/2` and `Deploy.hosts/1` (never called).

## [0.3.1] - 2026-05-06

### Changed

- The starter-config documentation now matches the packaged `examples/config` working tree, including the local `nix/nix-swarm/module.nix` bridge used by seeded machine files.
- The release packaging workflow now uses Node 24-compatible action versions, removing the GitHub-hosted Node 20 deprecation warning from release builds.

### Fixed

- Cluster and machine views now display the user-facing release version instead of the internal build digest suffix.
- Historical changelog references now use the canonical `ITM007/nix-swarm` repository name.

## [0.2.0] - 2026-05-06

### Added

- Added dedicated flake package outputs for operator workstations (`packages.<system>.operator`) and managed cluster nodes (`packages.<system>.cluster`) while keeping a compatibility combined package.
- Added automated GitHub release packaging that builds the Nix operator and cluster packages and uploads binary-cache tarballs as release assets.

### Changed

- Release installation docs now default to tracking the latest GitHub flake revision, with release pinning documented as an explicit opt-in.
- Example machine configs and bootstrap package overrides now point managed nodes at the dedicated cluster package output.

### Fixed

- The flake now exports the new package split consistently for both supported Linux systems.
- Security support guidance now matches the `0.2.x` release series.

## [0.1.5] - 2026-05-04

### Added

- Added root-level OSS contributor guidance and security reporting policy.

### Fixed

- Restore the packaged `swarm` wrapper's cookie bootstrap so bare `swarm` launches again after the `v0.1.4` release regression.
- Align the packaged Nix release metadata with the `0.1.5` application version.
- Replace real-style test IPs and internal hostnames with public-safe documentation values.

## [0.1.4] - 2026-05-04

### Fixed
- The packaged `swarm` wrapper now exports the discovered cookie into the release runtime again, so bare launches work with local config-root cookies and `swarm --help` no longer fails before the CLI starts.

## [0.1.3] - 2026-05-04

### Changed
- `swarm` now defaults its target from `NIX_SWARM_TARGET` or the first peer in the configured cluster file, so a configured workstation can launch the TUI without an explicit `--target`.

### Fixed
- The packaged operator now auto-discovers local cookies from `~/.config/nix-swarm/secrets/{nix-swarm.cookie,swarm.cookie}` before falling back to `/etc/nixos/...`.
- The release wrapper no longer blocks `swarm --help` just because no cookie is present.

## [0.1.2] - 2026-05-04

### Fixed
- The packaged `swarm` launcher now makes the seeded `~/.config/nix-swarm` tree user-writable, including upgrades from earlier read-only seeded copies.
- The packaged `nix-swarmd` entrypoint now resolves the same cookie sources as `swarm`, so direct `eval` and other release commands work consistently outside the NixOS module wrapper.
- Release install examples now use the working `git+https` tagged flake input form for the GitHub repository.

## [0.1.1] - 2026-05-04

### Changed
- The packaged operator now installs `swarm` as the primary TUI command while keeping `nix-swarm` as a compatibility wrapper and leaving `nix-swarmd` unchanged for managed nodes.
- Release examples and packaging docs now point operators at the `ITM007/nix-swarm` GitHub flake input and the default editable config root at `~/.config/nix-swarm`.

### Fixed
- User-facing launch help and remote diagnostics no longer hardcode the previous `v0.1.0` release label.
- The packaged starter tree is documented as a Git-friendly working copy for version-controlled cluster configuration.

## [0.1.0] - 2026-04-22

### Added
- Initial Nix-Swarm release for leaderless service orchestration across NixOS machines.
- A full-screen operator TUI for dashboard, map, machines, services, logs, dry-run/apply, and rolling updates.
- Integration and unit coverage for placement, deploy planning, bootstrap generation, and multi-node cluster behavior.
- Public release assets: MIT license, starter-config examples under `examples/config`, and rendered TUI screenshots for the README.

### Changed
- Nix-Swarm is now TUI-first for the public alpha; the old one-shot CLI subcommands were removed from the public surface.
- Launch-time options now focus on TUI startup, remote connection, and path overrides for local config editing/apply workflows.
- `nix-swarm` on NixOS is documented and packaged as the operator console, while `nix-swarmd` remains the node runtime.
- Simplified the sample Gitea service to use the stock NixOS `services.gitea` module for the common single-instance case, while moving placement decisions into the editable cluster config.
- Added `preferredNodes` placement support so cluster config can bias services toward specific machines.
- Standardized repository metadata for first-time publication with a project changelog and stricter ignore rules for generated and local-only files.

### Fixed
- Launch-time remote diagnostics now use TUI/operator wording instead of referring to removed CLI commands.
- The installed Nix package exposes `nix-swarm` as the operator TUI and `nix-swarmd` as the node runtime.
- Nix-Swarm cookies are loaded from systemd credentials at startup instead of being read into the Nix store.
- `shift+h/j/k/l` scrolling now works correctly instead of being intercepted by normal navigation handlers.
- The packaged `nix-swarm` CLI now fails when no cookie source is available instead of using a hardcoded fallback cookie.
- Remote deploy commands now validate target paths, run SSH in batch mode, and create restored secrets directories with restrictive permissions before relaxing directory traversal permissions.
- Cluster reconcile requests now return per-node results so callers can distinguish RPC failures from successful reconciliation.
- Generated machine/service files now reject unsafe names and quote Nix string values consistently.
