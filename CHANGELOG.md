# Changelog

All notable changes to this project will be documented in this file.

## [0.5.0] - 2026-07-07

### Added

- **Auto-deploy file watcher**: `nix-swarm watch` command starts a GenServer that monitors config files using Linux `inotify`. Config changes auto-deploy within 3 seconds — no manual apply needed.
- **Systemd user service**: `nix/nix-swarm-watcher.service` for 24/7 auto-deployment.
- **NixSwarm.Watcher** — Port-based `inotifywait` listener with 3 second debounce, fallback polling if unavailable.
- **NixSwarm.Executor.Server** — GenServer that serializes all `systemctl` calls, batch status checks (one `systemctl show` per N units), and short-lived status cache (200ms TTL). ~10x faster for multi-unit reconciliation.
- **NixSwarm.Watchdog** — `sd_notify` GenServer for `Type=notify` + `WatchdogSec=30` health monitoring.
- **NixSwarm.Telemetry** — 7 event types emitted via OTP's built-in `:telemetry` module at reconcile, RPC, systemctl, and deploy boundaries.
- **Concurrent reconciler** — `Task.async_stream(max_concurrency: 8)` replaces sequential `Enum.map` for unit operations.
- **Concurrent RPC sync** — `Task.async_stream` replaces O(n) sequential `:rpc.call` for peer service mode distribution.
- **`:persistent_term` cache** — `Config.current/0` cached until `invalidate_cache/0` is called, eliminating file reads on every reconcile tick.
- **`:sys` debug CLI** — `nix-swarm debug state` inspects live GenServer state via `:sys.get_state/1`.
- **Delete confirmation** — Pressing `d` on machines/services shows a confirmation dialog before deleting.
- **`shift+tab` previous view** — Symmetric with `tab` forward (was focus-cycling).
- **`R` reconnect key** — Reconnects Erlang distribution without restarting TUI.
- **Connection lost detection** — After 3 failed refreshes, shows `"connection lost"` help text.
- **Edit-exit flash** — Warns `"opening $EDITOR"` before exiting TUI to editor.
- **Footer shows `a/e/d` and `R`** — File management and reconnect visible in all views.

### Changed

- **Auto-deploy model**: Config changes auto-deploy on file save. The TUI is now read-only monitoring with emergency service controls (`b`/`z`/`x`). Manual `p`/`P`/`c`/`u` keys removed.
- **SSH port support**: `NIX_SWARM_SSH_PORT` env var and `host:port` notation in `deployHost`.
- **Rebalance on `cluster ensure`**: `update_remote` now calls `create_machine_config`, `maybe_create_flake`. `--source` properly resolves `cluster.nix`.
- **NixOS module**: `Type=notify` + `WatchdogSec=30` added to `nix-swarmd` service.
- **Remove auto-seed**: Example config is no longer silently copied on first run. Bootstrap explicitly via `nix-swarm cluster ensure`.

### Removed

- **`NixSwarm.Update` module** (259 lines) — manual rollout functionality replaced by auto-deploy.
- **`cluster update` CLI command** — replaced by `nix-swarm watch` auto-deploy.
- **Manual apply/dry-run** — `p`/`P`/`y` keys removed from TUI (config auto-deploys on save).
- **Reconcile/update keys** — `c`/`u` removed.
- **Rollout confirmation** — Entire rollout modal flow removed (auto-deploy replaces it).
- **Auto-seed on first run** — no more silent copy of example config.
- **~300 lines of dead code** in tui.ex (rollout/apply/reconcile functions).
- **`test/nix_swarm_update_test.exs`** — tests for removed module.

### Fixed

- SSH port 22 hardcoded: `NIX_SWARM_SSH_PORT` env var now honored.
- `cluster.nix` path resolution: `--source` correctly derives `cluster_file`.
- Rebuild flake attribute: `#default` appended for correct `nixosConfigurations` resolution.
- `.gitignore` filtering: stale `cluster/` dir cleaned, `/machines/` exclusion removed from synced source.
- Nix flake cache: `nix flake lock --update-input` forces re-evaluation of path inputs.
- nix-swarmd restart: explicit `systemctl restart nix-swarmd` added after `nixos-rebuild switch`.
- `delete_selected_config` now uses `action_confirmation` flow instead of immediate deletion.
- Apply keybinding: `p` = dry-run, `P` = apply (was confusing `y` = dry-run).
- Footer labels: `shift+tab prev`, `p/P dry/apply`, `a/e/d file`, `R reconnect`.
- `cycle_focused_container` unused after shift+tab repurposing.
- Deploy SSH commands honor `NIX_SWARM_SSH_PORT` and `UserKnownHostsFile=/dev/null` for Nix store SSH configs.

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
