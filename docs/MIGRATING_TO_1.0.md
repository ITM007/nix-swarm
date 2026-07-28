# Migrating to v1.0

The v1.0 line is a breaking change from the earlier 0.4.x/0.5 work-in-progress
behavior. Read this guide before applying a v1.0 configuration to an existing
cluster.

## Desired state and deployment

- Nix is the only desired-state source. Edit the flake and use `cluster plan`
  followed by `cluster apply --yes`.
- The file watcher and its systemd unit are gone. Saving a file no longer
  deploys automatically.
- Remote source synchronization and generated remote machine files are gone.
  The operator evaluates local `nixosConfigurations` and uses native
  `nixos-rebuild --target-host`.
- The deployment manifest must be exported as
  `lib.nixSwarm.deploymentManifest` with `schemaVersion = 1`, node metadata,
  and the NixOS configuration attribute for each deploy host.

## Operator access

Operators no longer receive the BEAM cookie and do not join distributed Erlang.
They use SSH to invoke the bounded `nix-swarm-query` helper through the local
Unix socket. Configure `operatorUsers` on every node and verify host keys before
using `cluster doctor`.

## Configuration changes

- `healthcheck` is display-only compatibility metadata; health is derived from
  systemd unit state and readiness.
- Ingress entries are routing metadata. Configure nginx, HAProxy, or another
  load balancer explicitly.
- `active`, `draining`, and `maintenance` node availability replace ad-hoc
  runtime placement changes.
- Optional autoscaling is CPU-only, bounded by Nix, and intended only for
  stateless or externally backed services.

## Credential migration

Run `cluster credentials --source . --yes` for enrollment. Existing matching
credentials are retained. Use `--rotate-credentials --yes` only during planned
maintenance; it creates a new cookie and coordinates agent restarts.

## Rollback

`cluster rollback --yes` uses the previous native NixOS generation. It does not
restore arbitrary mutable files or application data. Databases and other
stateful workloads require their own backup and rollback procedure.
