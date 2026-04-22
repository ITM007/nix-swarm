# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-04-22

### Added
- Initial Swarm release for leaderless service orchestration across NixOS machines.
- CLI commands for cluster status, membership, topology, restarts, logs, reconciliation, machine bootstrapping, and deploy/apply workflows.
- Integration and unit coverage for placement, deploy planning, bootstrap generation, and multi-node cluster behavior.

### Changed
- Documented the recommended CLI override for `--name` when distributed Erlang auto-detection needs an explicit local host or IP.
- Standardized repository metadata for first-time publication with a project changelog and stricter ignore rules for generated and local-only files.

### Fixed
- The CLI now derives a local node name for longname targets instead of reusing the remote host, which prevents failed distributed Erlang connections from a different machine.
- Remote connection and RPC failures now return clean `error:` output instead of raw runtime stack traces.
- `cluster members` output now includes a clear heading and queried-node context.
