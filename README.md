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

The CLI uses ANSI named colors, so the highlights follow your terminal theme, and structured output like status, members, defaults, and apply previews is rendered in ASCII tables.

Install it on a local NixOS workstation from a checkout:

```nix
# ~/NixFiles/flake.nix
inputs.swarm = {
  url = "path:/home/itm/Code/swarm";
  inputs.nixpkgs.follows = "nixpkgs";
};

# ~/NixFiles/home-manager/packages.nix
home.packages = with pkgs; [
  inputs.swarm.packages.${pkgs.stdenv.hostPlatform.system}.default
];
```

Then rebuild your user environment:

```bash
cd ~/NixFiles
home-manager switch --flake .#itm@amd
```

If that workstation is itself a managed Swarm node, the packaged `swarm` command automatically uses `/etc/nixos/nix-swarm/secrets/swarm.cookie` when it is readable. If it is only an operator workstation, point the CLI at your shared cluster cookie before running remote commands:

```bash
export SWARM_COOKIE_FILE=/path/to/swarm.cookie
```

To keep remote commands short without exposing the cookie in `ps`, export the cookie file once per shell:

```bash
export SWARM_COOKIE_FILE=./secrets/swarm.cookie
```

See the current defaults:

```bash
./swarm defaults
```

Talk to any reachable Swarm node:

```bash
./swarm --target swarm@192.168.1.226 status
./swarm --target swarm@192.168.1.226 status --summary
./swarm --target swarm@192.168.1.226 cluster members
./swarm --target swarm@192.168.1.226 cluster map
./swarm --target swarm@192.168.1.226 doctor
./swarm --target swarm@192.168.1.226 restart gitea
./swarm --target swarm@192.168.1.226 logs gitea --lines 100
./swarm --target swarm@192.168.1.226 reconcile
```

If the CLI cannot auto-detect the right local IP/hostname for distributed Erlang, override it explicitly:

```bash
./swarm --target swarm@192.168.1.226 --name swarmctl@192.168.1.121 status
```

Remote commands no longer have a built-in cookie default. Use one of:

- `--cookie-file /path/to/cookie`
- `--cookie YOUR_COOKIE`
- `SWARM_COOKIE_FILE=/path/to/cookie`
- `SWARM_COOKIE=YOUR_COOKIE`

If a connection fails, run the built-in doctor:

```bash
./swarm --target swarm@192.168.1.226 doctor
```

It checks:

- target host resolution
- TCP reachability to epmd (`4369`) and the default Swarm distribution port (`4370`)
- the effective local CLI node name
- whether the remote Swarm API actually answered

## How to change the cluster

This is the simple workflow:

1. edit `cluster/cluster.nix`
2. add, remove, or change service files under `cluster/services/`
3. update any machine files under `machines/` if needed
4. apply the change

Use the CLI to roll out the change:

```bash
./swarm apply --dry-run
./swarm apply
```

By default, `swarm apply` now validates every machine file, prints the dry-run plan, and applies to every machine file under `machines/*.nix`.

Override that behavior with flags like `--hosts`, `--source`, `--remote-path`, `--nixos-dir`, `--flake`, `--build-host`, or stop after the preview with `--dry-run`.

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
  --cookie-file /etc/nixos/nix-swarm/secrets/swarm.cookie
```

Generate it and deploy immediately:

```bash
./swarm add-machine \
  --output ./machines/node-d.nix \
  --node-name swarm@10.0.0.14 \
  --cookie-file /etc/nixos/nix-swarm/secrets/swarm.cookie \
  --hosts root@10.0.0.14 \
  --deploy
```

Then add the new node to `cluster/cluster.nix` and run `swarm apply`.

## Defining the cluster in Nix

`cluster/cluster.nix` is the main cluster file. It owns:

- peer membership
- node labels
- service placement
- replica count
- preferred machines
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

    services.gitea = {
      constraints = [ "gitea" ];
      preferredNodes = [ "swarm@192.168.1.226" ];
      settings.httpPort = 3003;
    };

    ingress.sites.gitea = {
      domain = "gitea.home";
      service = "gitea";
      ports = [ 3003 ];
      default = true;
    };
  };
}
```

That means yes: you can decide in `cluster.nix` how many copies of a service you want, which nodes are eligible through labels/constraints, and which specific machines should be preferred first with `preferredNodes`.

Useful defaults that reduce boilerplate:

- `services.swarm.services.<name>.replicas = 1`
- `services.swarm.services.<name>.unitTemplate = "%{service}.service"` for one replica
- `services.swarm.services.<name>.unitTemplate = "%{service}@%{slot}.service"` for multiple replicas
- `services.swarm.services.<name>.constraints = []`
- `services.swarm.services.<name>.preferredNodes = []`
- `services.swarm.runtime.connectIntervalMs = 500`
- `services.swarm.runtime.reconcileIntervalMs = 500`
- `services.swarm.runtime.generation = "nixos"`
- `services.swarm.openFirewall = false`
- `services.swarm.firewallInterfaces = []`

## Defining one service per file

Put each service in its own file under `cluster/services/`.

Example:

```nix
{ lib, ... }:
{
  networking.firewall.allowedTCPPorts = [ 3003 ];

  services.gitea.enable = true;
  services.gitea.stateDir = "/var/lib/gitea";
  services.gitea.settings.server.HTTP_PORT = 3003;

  systemd.services.gitea.wantedBy = lib.mkForce [];
}
```

## Security notes

- `swarmd` now reads its cookie at runtime, not from the Nix store. Set `services.swarm.cookieFile` to an absolute path on the target machine, such as `/etc/nixos/nix-swarm/secrets/swarm.cookie`.
- Swarm now installs both `swarm` and `swarmd` on enabled machines. `swarm` is the operator CLI; `swarmd` is the node runtime used by systemd. On a managed node, the installed `swarm` command automatically uses `/etc/nixos/nix-swarm/secrets/swarm.cookie` when it is readable.
- Distributed Erlang traffic is still plain Erlang distribution, not TLS. Keep Swarm on a trusted LAN/VPN segment and restrict the firewall to the cluster interface when possible.
- If you want Swarm to manage firewall rules for you, set `services.swarm.openFirewall = true;` and preferably scope it with `services.swarm.firewallInterfaces = [ "eth0" ];`.

That keeps the machine-local service definition simple. Placement stays in `cluster.nix`, and the service file only describes how that service runs on each node.

If you need multiple replicas of the same application on one machine with different units or ports, you can still use a templated unit such as `gitea@%{slot}.service`. The simple `gitea.service` pattern is for the common single-instance case.

Machine files can stay short too. With the local module import, `services.swarm.package` now defaults to `import ./package.nix { inherit pkgs; }`, so a machine file only needs:

```nix
services.swarm = {
  enable = true;
  nodeName = "swarm@192.168.1.226";
  cookieFile = ../secrets/swarm.cookie;
};
```

## Tiny ingress helper

Swarm now includes a small built-in ingress helper under the internal Nix module.

Instead of hand-writing nginx upstream blocks, you can declare:

```nix
services.swarm.ingress.sites.gitea = {
  domain = "gitea.home";
  service = "gitea";
  ports = [ 3003 ];
  clientMaxBodySize = "512m";
  default = true;
};
```

This helper:

- enables nginx automatically
- builds upstreams across all Swarm peers
- supports either explicit backend ports or one derived port per slot from `basePort`
- opens port `80/tcp`

If your service ports are not a simple `basePort + slot` pattern, you can set explicit ports instead:

```nix
services.swarm.ingress.sites.gitea.ports = [ 3000 3001 ];
```

For anything more complex than that, you can still write nginx config manually.

## ASCII cluster map

To get a high-level overview:

```bash
./swarm --target swarm@192.168.1.226 cluster map
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
4. run `./swarm apply --dry-run`
5. then run `./swarm apply`

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
./swarm apply --dry-run
./swarm apply
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
