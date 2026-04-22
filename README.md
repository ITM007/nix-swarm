# Swarm

Swarm is a small, leaderless Elixir/OTP orchestrator for NixOS machines.

It is built for this model:

- Nix is the source of truth
- every node runs the same Swarm runtime
- each node controls only its own local systemd units
- service ownership is computed locally from shared config plus live peers
- you can connect to any node with a CLI for status and operations

Swarm is intentionally **not** a container platform and **not** a storage orchestrator. v1 is for stateless or externally-backed services.

## What it does

At runtime:

1. Nix renders the cluster config onto each machine.
2. Every machine runs `swarmd`.
3. Nodes connect over distributed Erlang.
4. Every node computes the same placement locally.
5. Each node starts the units it owns and stops the ones it does not.
6. If a node disappears, the surviving nodes take over its work.

## Repository layout

The repo is now split into **user-edited cluster files** and **internal Swarm Nix files**.

```text
cluster/
  cluster.nix              # cluster topology, peer list, node labels, imported services
  services/
    gitea.nix              # one file per service

machines/
  nixos-2.nix              # one machine bootstrap file per host
  nixos-3.nix

nix/swarm/
  module.nix               # internal NixOS module for Swarm
  package.nix              # internal package definition
```

### What you edit

Most day-to-day changes should only touch:

- `cluster/cluster.nix`
- `cluster/services/*.nix`
- `machines/*.nix` when adding or changing hosts

You should not need to edit `nix/swarm/` during normal cluster use.

## Local development

```bash
nix shell nixpkgs#elixir nixpkgs#erlang
mix format
mix test
mix escript.build
mix run scripts/verify_cluster.exs
nix-build
```

## CLI commands

Build the CLI:

```bash
mix escript.build
```

Talk to any reachable Swarm node:

```bash
./swarm --target swarm@192.168.1.226 --cookie swarm status
./swarm --target swarm@192.168.1.226 --cookie swarm cluster members
./swarm --target swarm@192.168.1.226 --cookie swarm cluster map
./swarm --target swarm@192.168.1.226 --cookie swarm restart gitea
./swarm --target swarm@192.168.1.226 --cookie swarm logs gitea --lines 100
./swarm --target swarm@192.168.1.226 --cookie swarm reconcile
```

If the CLI cannot auto-detect the right local IP/hostname for distributed Erlang, override it explicitly:

```bash
./swarm --target swarm@192.168.1.226 --cookie swarm --name swarmctl@192.168.1.121 status
```

## How to change the cluster

This is the simple workflow:

1. edit `cluster/cluster.nix`
2. add, remove, or change service files under `cluster/services/`
3. update any machine files under `machines/` if needed
4. apply the change

Use the CLI to roll out the change:

```bash
./swarm apply --dry-run --hosts nixos-2,nixos-3
./swarm apply --hosts nixos-2,nixos-3
```

`swarm apply` now validates the declarative config before it touches any host.

`--dry-run`:

- evaluates every machine module under `machines/`
- confirms the cluster/service/ingress config composes through the NixOS module system
- prints the exact sync and rebuild commands that would run

The real apply command:

- syncs the repo to each host
- updates `/etc/nixos/nix-swarm`
- runs `nixos-rebuild switch` on each host

Optional flags:

```bash
./swarm apply \
  --dry-run \
  --hosts root@10.0.0.14,root@10.0.0.15 \
  --source . \
  --remote-path /etc/nixos/nix-swarm \
  --nixos-dir /etc/nixos
```

If you already have another deployment tool you like, you can skip `swarm apply` and use plain `nixos-rebuild`, `deploy-rs`, or `colmena`. The important part is that the cluster files stay declarative.

## Bootstrapping a new machine

Generate a machine file:

```bash
./swarm add-machine \
  --output ./machines/node-d.nix \
  --node-name swarm@10.0.0.14 \
  --cookie-file ../secrets/swarm.cookie
```

Generate it and deploy immediately:

```bash
./swarm add-machine \
  --output ./machines/node-d.nix \
  --node-name swarm@10.0.0.14 \
  --cookie-file ../secrets/swarm.cookie \
  --hosts root@10.0.0.14 \
  --deploy
```

Then add the new node to `cluster/cluster.nix` and run `swarm apply`.

## Defining the cluster in Nix

`cluster/cluster.nix` is the main cluster file. It owns:

- peer membership
- node labels
- runtime intervals
- which service files are imported

Current example:

```nix
{ ... }:
{
  imports = [
    ./services/gitea.nix
  ];

  services.swarm = {
    peers = [
      "swarm@192.168.1.226"
      "swarm@192.168.1.121"
    ];

    nodes = {
      "swarm@192.168.1.226".labels = [ "gitea" "ingress" ];
      "swarm@192.168.1.121".labels = [ "gitea" "ingress" ];
    };

    runtime = {
      connectIntervalMs = 1000;
      reconcileIntervalMs = 1000;
      generation = "home-lab";
    };
  };
}
```

To add or remove a service, add or remove its import in this file.

## Defining one service per file

Put each service in its own file under `cluster/services/`.

Example:

```nix
{ lib, pkgs, ... }:
{
  systemd.services."gitea@" = {
    description = "Gitea slot %i";
    wantedBy = lib.mkForce [];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.gitea}/bin/gitea web --config /etc/swarm-gitea/%i/app.ini";
      Restart = "always";
    };
  };

  services.swarm.services.gitea = {
    replicas = 2;
    unitTemplate = "gitea@%{slot}.service";
    constraints = [ "gitea" ];
    settings = {
      domain = "gitea.home";
    };
  };

  services.swarm.ingress.sites.gitea = {
    domain = "gitea.home";
    service = "gitea";
    basePort = 3000;
    websocket = true;
    clientMaxBodySize = "512m";
    default = true;
  };
}
```

That keeps service behavior local to one file. If you want to change Gitea, you edit `cluster/services/gitea.nix` and nothing else.

## Tiny ingress helper

Swarm now includes a small built-in ingress helper under the internal Nix module.

Instead of hand-writing nginx upstream blocks, you can declare:

```nix
services.swarm.ingress.sites.gitea = {
  domain = "gitea.home";
  service = "gitea";
  basePort = 3000;
  websocket = true;
  clientMaxBodySize = "512m";
  default = true;
};
```

This helper:

- enables nginx automatically
- builds upstreams across all Swarm peers
- derives one backend port per slot from `basePort`
- opens port `80/tcp`

If your service ports are not a simple `basePort + slot` pattern, you can set explicit ports instead:

```nix
services.swarm.ingress.sites.gitea.ports = [ 3000 3001 ];
```

For anything more complex than that, you can still write nginx config manually.

## ASCII cluster map

To get a high-level overview:

```bash
./swarm --target swarm@192.168.1.226 --cookie swarm cluster map
```

It shows:

- configured nodes
- which nodes are up
- which slots each node owns
- a compact per-service ownership summary

## Packaging on NixOS

Yes, packaging Swarm as a Nix package is the right approach.

This repo ships:

- `default.nix`
- `flake.nix`
- `nix/swarm/package.nix`

Build it with:

```bash
nix-build
```

or:

```bash
nix build .#swarm
```

The NixOS module lives at:

- `nix/swarm/module.nix`

Compatibility wrappers still exist at:

- `nix/package.nix`
- `nix/swarm-module.nix`

## Loading Swarm onto NixOS machines

### Simple dev or home-lab path

The simplest path is:

1. build or reference the Swarm package
2. import the generated machine file from `machines/`
3. make sure that machine file imports `cluster/cluster.nix`
4. run `./swarm apply --dry-run --hosts ...`
5. then run `./swarm apply --hosts ...`

This is simple because SSH is already enough for a small fleet.

### Production path

For production, keep the same config layout but use a packaged release and a more repeatable rollout tool.

Good options:

- `swarm apply` for a very small fleet
- `deploy-rs`
- `colmena`

`swarm apply` uses SSH underneath and is good enough for small clusters. For larger or more repeatable environments, `deploy-rs` or `colmena` are better than hand-written SSH loops.

## Verified two-node demo

This repo includes a real two-node demo using:

- `machines/nixos-2.nix`
- `machines/nixos-3.nix`
- `cluster/cluster.nix`
- `cluster/services/gitea.nix`

The live deployment that passed used:

```bash
./swarm apply --dry-run --hosts nixos-2,nixos-3
./swarm apply --hosts nixos-2,nixos-3
```

The checks that passed on the real machines were:

1. cluster peering
2. deterministic placement
3. `cluster map` output
4. local service restart recovery
5. node-loss failover
6. reconvergence after the failed node returned
7. ingress still serving `gitea.home` while one node was down

Useful commands for that exact demo:

```bash
./swarm --target swarm@192.168.1.226 --cookie <cookie> cluster map
./swarm --target swarm@192.168.1.226 --cookie <cookie> status
./swarm --target swarm@192.168.1.226 --cookie <cookie> logs gitea --lines 20

curl --resolve gitea.home:80:192.168.1.226 http://gitea.home/
curl --resolve gitea.home:80:192.168.1.121 http://gitea.home/
```

## Important SQLite / Gitea caveat

The included Gitea demo is **not** true HA Gitea.

Each slot has its own local SQLite database, so this demo proves:

- placement
- restart behavior
- failover
- ingress routing

It does **not** prove shared application state across nodes. Real multi-node Gitea still needs shared or external database and storage services.

## Will DNS work?

Not by itself.

Swarm handles placement. It does **not** publish or manage DNS.

If you want `http://gitea.home` to route into the cluster, DNS must point at an ingress layer that is itself highly available enough for your needs.

Practical options:

1. round-robin DNS across ingress nodes
2. a VIP or load balancer in front of ingress nodes
3. local DNS pointing at a separate HA front door

So yes, `http://gitea.home` can work, but only if DNS points at something that can still reach live cluster backends when a node goes down.

## Current limitations

- leaderless and eventually consistent
- network partitions can temporarily create duplicate instances
- no built-in shared storage or database replication
- intended for stateless or externally-backed workloads

That tradeoff is intentional to keep the project small and understandable.
