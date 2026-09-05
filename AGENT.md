# Nix-Swarm contributor guide

Nix-Swarm is a code-first orchestrator for systemd services on small NixOS
clusters: stateless replicas plus declared single-writer state with scheduled
backup and verified restore-on-placement. Keep the design narrow:

- Nix is the only desired-state model and deployment history.
- systemd owns process lifecycle, dependencies, readiness, credentials,
  resources, restarts, and logs.
- trusted BEAM peers own membership, deterministic placement, supervision, and
  reconciliation.
- DETS stores node-local operational observations, never desired state.
- the operator CLI and TUI are read-only except for explicit Nix deployment
  commands.

Do not add a container runtime, secret store, mutable service controls, Mnesia
database, or consensus layer without an explicit scope change. Overlay
networks, backup targets, and edge proxies are optional user-owned integration
points (see docs/STATEFUL_SERVICES.md); the core never depends on one.
Temporary duplicate instances during a network partition are an accepted
leaderless tradeoff for stateless replicas; stateful services are
single-writer and recover by declared restore, never by live sync.

## Simplified public contract

The supported operator surface is deliberately small:

- launch the read-only TUI, or use `help` and `version`;
- inspect with `cluster doctor`, `cluster status`, and `service logs`;
- preview and mutate Nix with `cluster plan` and `cluster apply --yes`;
- use `cluster rollback --yes`, `cluster upgrade --yes`, and
  `cluster credentials rotate --yes` for explicit deployment maintenance;
- use `service restart --name NAME --yes` for a bounded maintenance restart;
- heal a stateful service onto a live eligible node with
  `cluster heal NAME --yes` after its owner failed.

Starting and stopping are declarative: set `replicas` above zero or to zero in
Nix and apply. Machine provisioning, live migration, network-mounted storage,
and live file sync are outside the product. Declared application state is in
scope as single-writer state directories (`state.dirs`): Nix-Swarm schedules
their backup (borgmatic to an operator-chosen repository) and restores the
latest snapshot onto a surviving eligible node before starting the unit. A
stateful service never auto-starts without its state (`:awaiting_heal`) and
never runs with `replicas > 1`. CPU-and-memory autoscaling is limited to
existing declared service capacity; it never rewrites Nix or manages a
stateful workload.

The TUI is a read-only projection. Nix files and Git are the authoritative
record; runtime observations are not a second desired-state store. Removed
commands return a migration error rather than silently invoking compatibility
paths. Users should replace old bootstrap aliases with `cluster apply`,
`cluster members` with `cluster status`, and service scaffolding commands with
an edited copy of `examples/starter`.

Public Nix service configuration is intentionally limited to replicas, an
optional unit template, allowed nodes, the small autoscaling policy, and the
optional `state` block (state directories, backup schedule and target,
restore kind, auto-heal policy). Ingress, healthcheck metadata, arbitrary
settings, preferred nodes, labels/constraints, per-node replica caps, and
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
- Agent BEAM ports open only on trusted interfaces — the LAN by default, or
  an encrypted mesh when peers span networks (`openFirewall` +
  `firewallInterfaces`, never every interface).
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
