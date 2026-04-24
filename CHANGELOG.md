# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-04-22

### Added
- Initial Swarm release for leaderless service orchestration across NixOS machines.
- A full-screen operator TUI for dashboard, map, machines, services, logs, dry-run/apply, and rolling updates.
- Integration and unit coverage for placement, deploy planning, bootstrap generation, and multi-node cluster behavior.
- Public release assets: MIT license, starter-config examples, and rendered TUI screenshots for the README.

### Changed
- Swarm is now TUI-first for the public alpha; the old one-shot CLI subcommands were removed from the public surface.
- Launch-time options now focus on TUI startup, remote connection, and path overrides for local config editing/apply workflows.
- `swarm` on NixOS is documented and packaged as the operator console, while `swarmd` remains the node runtime.
- Simplified the sample Gitea service to use the stock NixOS `services.gitea` module for the common single-instance case, while moving placement decisions into `cluster/cluster.nix`.
- Added `preferredNodes` placement support so cluster config can bias services toward specific machines.
- Standardized repository metadata for first-time publication with a project changelog and stricter ignore rules for generated and local-only files.

### Fixed
- Launch-time remote diagnostics now use TUI/operator wording instead of referring to removed CLI commands.
- The installed Nix package exposes `swarm` as the operator TUI and `swarmd` as the node runtime.
- Swarm cookies are no longer read into the Nix store or exposed through the `swarmd` systemd environment.
- `shift+h/j/k/l` scrolling now works correctly instead of being intercepted by normal navigation handlers.
