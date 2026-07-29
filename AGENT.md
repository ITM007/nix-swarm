# Nix-Swarm contributor guide

Nix-Swarm is a code-first orchestrator for stateless or externally backed
systemd services on small NixOS clusters. Keep the design narrow:

- Nix is the only desired-state model and deployment history.
- systemd owns process lifecycle, dependencies, readiness, credentials,
  resources, restarts, and logs.
- trusted BEAM peers own membership, deterministic placement, supervision, and
  reconciliation.
- DETS stores node-local operational observations, never desired state.
- the operator CLI and TUI are read-only except for explicit Nix deployment
  commands.

Do not add a container runtime, overlay network, secret store, mutable service
controls, Mnesia database, or consensus layer without an explicit scope change.
Temporary duplicate instances during a network partition are an accepted
leaderless tradeoff.

## Simplified public contract

The supported operator surface is deliberately small:

- launch the read-only TUI, or use `help` and `version`;
- inspect with `cluster doctor`, `cluster status`, and `service logs`;
- preview and mutate Nix with `cluster plan` and `cluster apply --yes`;
- use `cluster rollback --yes`, `cluster upgrade --yes`, and
  `cluster credentials rotate --yes` for explicit deployment maintenance;
- use `service restart --name NAME --yes` for a bounded maintenance restart.

Starting and stopping are declarative: set `replicas` above zero or to zero in
Nix and apply. Databases, volumes, storage, live migration, and machine
provisioning are outside the product. CPU-and-memory autoscaling is limited to
existing declared service capacity; it never rewrites Nix or manages a
stateful workload.

The TUI is a read-only projection. Nix files and Git are the authoritative
record; runtime observations are not a second desired-state store. Removed
commands return a migration error rather than silently invoking compatibility
paths. Users should replace old bootstrap aliases with `cluster apply`,
`cluster members` with `cluster status`, and service scaffolding commands with
an edited copy of `examples/starter`.

Public Nix service configuration is intentionally limited to replicas, an
optional unit template, allowed nodes, and the small autoscaling policy.
Ingress, healthcheck metadata, arbitrary settings, preferred nodes,
labels/constraints, per-node replica caps, readiness/runtime timing, and
canary/parallel rollout controls are not product options. Configure routing,
service readiness, credentials, and exceptional systemd behavior in the
service's own NixOS modules or standard systemd overrides.

## Product boundary

Nix-Swarm starts with a target that is **already running NixOS**. Users own
installation, disks, hardware configuration, and boot. The supported handoff is
SSH, privilege, architecture and disk-space checks, trusted private-network
reachability, and a complete `.nix` inventory. `cluster apply` is the first
Nix-Swarm mutation; preflight and bootstrap begin there. `nixos-anywhere` and
Disko can appear only as optional user-owned preparation examples, never as
release gates.

## Runtime flow

1. The NixOS module renders an Erlang terms configuration.
2. `NixSwarm.Cluster` connects only configured distributed-Erlang peers.
3. `NixSwarm.Placement` deterministically assigns service slots to live,
   eligible nodes.
4. `NixSwarm.Reconciler` idempotently starts or stops only local systemd units.
5. `NixSwarm.OperationalState` snapshots local observations in DETS.
6. `NixSwarm.QueryServer` exposes a bounded read-only Unix-socket protocol.
7. `NixSwarm.Remote` reaches that socket through `nix-swarm-query` over SSH;
   operators never receive the BEAM cookie or arbitrary RPC.
8. `NixSwarm.Deploy` evaluates complete NixOS closures, performs bounded
   health-gated batches, and uses native NixOS generation rollback.

The agent runs as the `nix-swarm` system user. Generated polkit rules authorize
only exact unit names derived from Nix. Destructive reconciliation is blocked
while peer config digests differ.

## Security invariants

- Never place cookies or other credentials in argv, environment, logs, the Nix
  store, generated public settings, or package sources.
- Agent BEAM ports belong only on a trusted encrypted overlay interface.
- Do not expose arbitrary Erlang MFA, unsafe ETF decoding, shell evaluation, or
  user-derived systemd unit names.
- Keep SSH host-key verification enabled and external commands bounded.
- Treat journald text as untrusted terminal input.
- Preserve the unprivileged daemon, exact systemd authorization, socket
  allowlist, rollout health gates, and resource limits.

## Important paths

- `lib/nix_swarm/`: OTP runtime, operator, deployment, and TUI
- `nix/nix-swarm/module.nix`: NixOS options and hardened systemd service
- `nix/nix-swarm/packages.nix`: minimal release source and wrappers
- `examples/starter/`: packaged one-node starter
- `examples/config/`: larger two-node example
- `test/`: unit, contract, distributed, security, and VM checks
- `docs/`: concise user and operator documentation

## Required verification

```bash
mix format --check-formatted
mix clean
mix compile --warnings-as-errors
mix hex.audit
mix test --warnings-as-errors --cover
nix flake check --print-build-logs
```

Elixir 1.20 signature inference is enabled for normal and test compilation.
Preserve `infer_signatures: true`, fix compiler type contradictions, and retain
useful behaviours, callbacks, specs, and types.

Use `path:.#...` when validating uncommitted flake files because Git flakes omit
untracked paths. Preserve unrelated working-tree changes and never commit
credentials.
