# Changelog

All notable changes to this project will be documented in this file.

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
- Release examples and packaging docs now point operators at the `ITM007/swarm` GitHub flake input and the default editable config root at `~/.config/nix-swarm`.

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
