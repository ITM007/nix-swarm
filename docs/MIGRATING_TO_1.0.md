# Migrating to v1.0

The v1.0 line is a breaking change from the earlier 0.4.x/0.5 work-in-progress
behavior. Read this guide before applying a v1.0 configuration to an existing
cluster.

## Desired state and deployment

- Nix is the only desired-state source. Edit the flake and use `cluster plan`
  followed by `cluster apply --yes`.
- Saving a file no longer deploys automatically; there is no file watcher.
- Remote source synchronization and generated remote machine files are gone.
  The operator evaluates local `nixosConfigurations` and uses native
  `nixos-rebuild --target-host`.
- The deployment manifest is exported as `lib.nixSwarm.deploymentManifest` with
  `schemaVersion = 1`, node metadata, and the NixOS configuration attribute for
  each deploy host.

## Operator access

Operators do not receive the BEAM cookie or join distributed Erlang. They use
SSH to invoke the bounded `nix-swarm-query` helper through the local Unix socket.
Configure `operatorUsers` on every node and verify host keys before using
`cluster doctor`.

## Configuration changes

- Remove `healthcheck`, `settings`, and `ingress` metadata from Nix-Swarm
  service definitions. Configure health, routing, ports, and credentials directly
  with ordinary NixOS/systemd modules; Nix-Swarm derives readiness from unit
  state.
- Service definitions now use `replicas`, `unitTemplate`, `allowedNodes`, and
  optional CPU/memory `autoscaling` bounds. Remove labels, constraints,
  preferred-node lists, per-node replica limits, and rollout tuning fields.
- Start, stop, and scale declaratively by changing `replicas` and applying the
  resulting NixOS generation. Use `service restart --name NAME --target NODE
  --yes` only for an explicit bounded restart.
- Configure optional Caddy routing through the standard NixOS `services.caddy`
  module. Keep routes, TLS, and static health-checked candidate backends in
  user-owned Nix. Nix-Swarm manages the ordinary `caddy.service` placement but
  never edits Caddy configuration or calls the Admin API.
- `active`, `draining`, and `maintenance` node availability replace ad-hoc
  runtime placement changes.
- Autoscaling supports CPU and memory, remains bounded by Nix, and is intended
  only for stateless or externally backed services.

## CLI changes

- Replace `cluster init`, `cluster ensure`, and `cluster rebuild` with
  `cluster apply`.
- Replace `cluster members` with `cluster status`.
- Replace service scaffolding commands with copied and edited Nix modules from
  `examples/starter`.
- Replace `cluster upgrade prepare` with `cluster upgrade --yes`, or update the
  input manually and use `cluster plan` before `cluster apply`.
- Use `cluster credentials rotate --yes` for explicit credential rotation.

## Credential migration

Run `cluster credentials rotate --source . --yes` only during planned
maintenance. Matching existing credentials are retained by normal apply;
rotation coordinates agent restarts and restores the previous cookie if the
operation fails.

## Rollback

`cluster rollback --yes` uses the previous native NixOS generation. It does not
restore arbitrary mutable files, Caddy certificate state, or application data.
Databases and other stateful workloads require their own backup and rollback
procedure.
