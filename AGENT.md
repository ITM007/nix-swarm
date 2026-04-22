# Swarm agent handbook

## Project purpose

Swarm is a leaderless Elixir/OTP orchestrator for small NixOS clusters.

The intended model is:

- Nix defines the desired cluster state
- every machine runs the same long-lived Swarm runtime
- each node computes service ownership from the shared config plus current live peers
- each node only starts/stops local systemd units
- operators use a CLI to connect to any reachable node for status and operational actions

This project is intentionally **not** a container platform and **not** a consensus-based scheduler. v1 is small on purpose.

## Current implementation status

The Rust scaffold has already been replaced with a working Elixir/OTP implementation.

Implemented today:

- OTP application with peer connectivity and periodic reconciliation
- deterministic placement with replica spreading across eligible nodes
- systemd executor for real hosts
- fake executor for tests and local verification
- CLI entrypoint (`Swarm.CLI`) built as an escript
- machine bootstrap helper (`Swarm.Bootstrap`) for generating NixOS host modules and optional deploys
- CLI apply helper (`Swarm.Deploy`) for validating and syncing declarative cluster changes to hosts
- ASCII cluster overview via CLI
- user-edited cluster layout under `cluster/` plus machine stubs under `machines/`
- internal NixOS module/package files under `nix/swarm/`
- small built-in ingress helper under `nix/swarm/ingress.nix`
- Nix package and flake entrypoints (`default.nix`, `nix/swarm/package.nix`, `flake.nix`)
- three-node integration test
- three-node manual verification script

## Scope boundaries

Treat these as hard constraints unless the user explicitly changes them:

- v1 is for **stateless** or **externally-backed** services only
- Nix remains the source of truth for desired state
- the CLI is not the source of truth for service definitions
- the cluster is leaderless and eventually consistent
- temporary duplicate instances during partitions are acceptable in v1
- stateful HA storage/database orchestration is out of scope

For Gitea specifically:

- Swarm may orchestrate multiple Gitea app instances
- Swarm does **not** solve Gitea shared database/storage in v1

## Architecture overview

### Top-level flow

1. Nix renders a `swarm.config` Erlang terms file for each machine.
2. The node runs the same `:swarm` OTP application.
3. `Swarm.Cluster` connects configured peers and tracks the live membership view.
4. `Swarm.Placement` computes service-slot ownership deterministically from:
   - service definition
   - live configured peers
   - node labels / constraints
5. `Swarm.Reconciler` starts owned units and stops unowned units on the local machine.
6. `Swarm.API` exposes status/restart/log/reconcile operations for remote callers.
7. `Swarm.CLI` connects to any node and talks to `Swarm.API` over distributed Erlang RPC.

### Important invariants

- only **configured peers** participate in placement; arbitrary connected nodes must not affect scheduling
- placement is deterministic and local; there is no central assigner
- reconciliation is periodic and idempotent
- local execution happens through an executor adapter
- service ownership should spread replicas across eligible nodes before reusing a node
- partitions may cause temporary over-replication because the system is leaderless

## Module guide

### `Swarm.Application`

Starts the runtime supervision tree.

Current children:

- `Swarm.Cluster`
- `Swarm.Reconciler`

### `Swarm.Config`

Runtime config loader and normalizer.

Config sources:

- `Application.get_env(:swarm, :cluster_config)` for tests/dev
- `SWARM_CONFIG_PATH` / app env `:config_path` for rendered config files

Config format:

- Erlang terms file, not JSON/TOML
- normalized into:
  - `peers`
  - `nodes`
  - `services`
  - `runtime`

### `Swarm.Service`

Service-spec normalization helpers.

Encapsulates:

- replica count normalization
- constraint handling
- unit template rendering
- slot enumeration

### `Swarm.Cluster`

Peer connectivity loop.

Responsibilities:

- periodically attempt `Node.connect/1` to configured peers
- expose the live configured peer set
- ignore non-cluster nodes for placement

### `Swarm.Placement`

Deterministic ownership logic.

Current strategy:

- rank eligible nodes per service using a stable hash
- cycle service slots across that ranking
- if there are more replicas than eligible nodes, ownership wraps around

This is what enforces spreading when there are enough nodes.

### `Swarm.Reconciler`

Periodic local convergence loop.

Responsibilities:

- compute desired local ownership
- ensure owned units are running
- ensure unowned units are stopped
- provide local status and restart helpers

### `Swarm.Executor`

Executor abstraction.

Adapters:

- `Swarm.Executor.Systemd`
- `Swarm.Executor.Fake`

Use the fake executor for tests and local cluster verification. Use the systemd executor for real hosts.

### `Swarm.API`

Remote node-facing API used by the CLI and tests.

Current operations:

- cluster status
- cluster members
- cluster overview
- reconcile
- restart service
- logs

### `Swarm.CLI`

Human/operator entrypoint.

Important details:

- starts a distributed Erlang node if needed
- connects to a target peer
- calls `Swarm.API` over RPC
- is built as an escript via `mix escript.build`
- also has local-only helper flows such as `add-machine` and `apply`

### `Swarm.Bootstrap`

Local NixOS bootstrap helper.

Responsibilities:

- generate a host-local NixOS module file for a new machine
- keep shared cluster/service definitions under `cluster/`
- optionally deploy the generated machine config through `Swarm.Deploy`

### `Swarm.Deploy`

Local rollout helper.

Responsibilities:

- sync the repo to one or more remote NixOS machines over SSH
- validate machine modules under `machines/` before any remote mutation
- replace the managed repo path on the target
- run `nixos-rebuild switch` on each target
- support a dry-run mode that validates config and prints the exact planned commands
- keep the operator workflow simple: edit `cluster/` or `machines/`, then run `swarm apply`

## Files and directories that matter most

- `mix.exs` - project definition and escript entrypoint
- `default.nix` / `flake.nix` / `nix/swarm/package.nix` - package entrypoints
- `lib/swarm/` - runtime implementation
- `test/integration/three_node_cluster_test.exs` - strongest behavioral regression test
- `test/support/test_cluster.ex` - peer-cluster test harness
- `scripts/verify_cluster.exs` - manual end-to-end three-node verification
- `cluster/cluster.nix` - user-edited cluster topology and service imports
- `cluster/services/*.nix` - one file per user-edited service
- `machines/*.nix` - one bootstrap file per host
- `nix/swarm/module.nix` - internal NixOS integration module
- `nix/swarm/ingress.nix` - tiny nginx/front-door helper for slot-based services

## Testing and verification workflow

Always prefer these commands before concluding a change is done:

```bash
nix shell nixpkgs#elixir nixpkgs#erlang --command mix format
nix shell nixpkgs#elixir nixpkgs#erlang --command mix test
nix shell nixpkgs#elixir nixpkgs#erlang --command mix escript.build
nix shell nixpkgs#elixir nixpkgs#erlang --command mix run scripts/verify_cluster.exs
```

What they cover:

- formatting
- unit tests
- three-node integration test
- CLI build
- live three-node verification with restart/log/failover checks

## Deployment model

The current NixOS module expects a package exposing `bin/swarm` (for a release) and renders `SWARM_CONFIG_PATH` for the node.

Simple deployment expectations:

- package the app as a Nix package for production
- keep user-edited topology under `cluster/` and host stubs under `machines/`
- import `nix/swarm/module.nix` in host configs
- set `services.swarm.package` to the built package
- deploy with `swarm apply --dry-run --hosts ...` followed by `swarm apply --hosts ...`, or use `nixos-rebuild` over SSH for a small fleet

SSH is the simplest deployment transport and is good enough for small clusters. For larger or more repeatable multi-machine deployments, prefer `deploy-rs` or `colmena` instead of ad hoc shell scripts.

DNS is **not** managed by Swarm itself. If a user expects `http://gitea.home` to reach the cluster, DNS must point to an ingress/front-door layer such as one or more Swarm-managed reverse proxy nodes or a VIP/load balancer. Swarm handles placement; it does not publish DNS records.

The new ingress helper only reduces nginx/front-door boilerplate. It does not solve DNS publishing or HA DNS by itself.

## Guidance for future agents

### When editing placement or cluster behavior

You must re-run:

- `mix test`
- `mix run scripts/verify_cluster.exs`

because the three-node behavior is the real contract.

### When editing config or Nix integration

Keep these aligned:

- `Swarm.Config`
- `nix/swarm/module.nix`
- `cluster/cluster.nix`
- `cluster/services/*.nix`
- `README.md`

### When adding features

Prefer keeping behavior local to the module that owns it:

- config parsing in `Swarm.Config`
- slot ownership in `Swarm.Placement`
- execution in the executor modules
- cluster-facing operations in `Swarm.API`

Avoid smearing service orchestration logic across unrelated modules.

### When tempted to add complexity

Remember the project goals:

- keep it simple
- keep it leaderless
- keep Nix as the source of truth
- do not quietly expand into stateful-storage orchestration

If a change pushes the project toward consensus, state replication, or mutable control-plane state, call that out explicitly.
