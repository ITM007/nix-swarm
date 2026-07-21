# Release and support policy

## v1.0 release gate

Before tagging v1.0, all of the following must pass:

- `nix develop --command mix format --check-formatted`
- `nix develop --command mix compile --warnings-as-errors`
- `nix develop --command mix hex.audit`
- `nix develop --command mix test --warnings-as-errors --cover`
- `nix flake check --print-build-logs` on x86_64-linux
- packaged operator smoke tests for `--help`, `--version`, and `cluster plan`
- a real multi-node rollout, failed activation, automatic rollback, node reboot,
  partition recovery, and credential rotation exercise

The supported v1.0 workload is stateless or externally backed systemd services
on NixOS. Nix-Swarm does not provide consensus, fencing, volumes, a routing
mesh, or database replication.

## Versioning

The stable interfaces are the CLI commands, NixOS module options,
`lib.nixSwarm.deploymentManifest` schema, and documented upgrade procedure.
Elixir modules not described as public are internal implementation details.

Release artifacts are built from a tag such as `v1.0.0`. Starter flakes and
installation examples should pin that tag for stable deployments rather than
tracking the moving default branch.

## Support

During the pre-1.0 period, the current branch is the development target and
0.4.x remains the latest supported release. After v1.0, security fixes cover the
latest v1.0.x patch release and current development branch. Older releases are
unsupported after a newer patch release is published.
