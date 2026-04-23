# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-04-22

### Added
- Initial Swarm release for leaderless service orchestration across NixOS machines.
- CLI commands for cluster status, membership, topology, restarts, logs, reconciliation, machine bootstrapping, and deploy/apply workflows.
- Integration and unit coverage for placement, deploy planning, bootstrap generation, and multi-node cluster behavior.

### Changed
- Documented the recommended CLI override for `--name` when distributed Erlang auto-detection needs an explicit local host or IP.
- Added a `doctor` CLI command, compact `status --summary` output, and richer connection-failure diagnostics with concrete fixes.
- Added a `defaults` CLI command and pushed more behavior into sensible defaults so common commands and Nix files stay shorter.
- `swarm apply` now defaults to validating, previewing, and targeting every machine file under `machines/*.nix`, while still allowing explicit overrides.
- Simplified the sample Gitea service to use the stock NixOS `services.gitea` module for the common single-instance case, while moving placement decisions into `cluster/cluster.nix`.
- Added `preferredNodes` placement support so cluster config can bias services toward specific machines.
- Standardized repository metadata for first-time publication with a project changelog and stricter ignore rules for generated and local-only files.

### Fixed
- The CLI now derives a local node name for longname targets instead of reusing the remote host, which prevents failed distributed Erlang connections from a different machine.
- Remote connection and RPC failures now return clean `error:` output instead of raw runtime stack traces.
- `cluster members` output now includes a clear heading and queried-node context.
- The installed Nix package now exposes `swarm` as the operator CLI and `swarmd` as the node runtime, so SSH shells on cluster nodes can run Swarm commands directly.
- Swarm cookies are no longer read into the Nix store or exposed through the `swarmd` systemd environment, and remote CLI commands no longer fall back to the insecure default cookie `swarm`.
- `swarm apply` now terminates SSH option parsing explicitly and evaluates machine files through a quoted Nix path, closing command-injection edge cases.
