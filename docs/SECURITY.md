# Security model

## Trust boundaries

- Nix code is trusted desired state.
- Agents are trusted cluster members and share one BEAM cookie.
- Operators are less trusted: they use SSH plus a local Unix socket that allows only overview, membership, and bounded log queries.
- Workload logs are untrusted and have terminal control sequences removed before display or export.

The operator does not join distributed Erlang, receive the cookie, or expose arbitrary RPC. `nix-swarmd` runs as the `nix-swarm` system user. A generated polkit rule allows it to start, stop, restart, or reset only the exact units rendered from Nix.

## Agent network

Distributed Erlang is authenticated by the cookie but is not encrypted in the default configuration. Bind and firewall ports `4369/tcp` and `4370/tcp` to a trusted encrypted WireGuard/Tailscale interface. Never expose them to the Internet or an untrusted LAN.

```nix
services.nix-swarm = {
  openFirewall = true;
  firewallInterfaces = [ "wg0" ];
};
```

The module rejects an unscoped firewall opening. A single-node cluster should leave `openFirewall = false`.

## Credentials

The source cookie must be an absolute path outside `/nix/store`. At startup, systemd copies it through `LoadCredential`; the launcher validates its length, installs it as private `HOME/.erlang.cookie`, clears related environment variables, and never places it in process arguments.

Recommended target mode is root-owned `0400`. Generate and install it with:

```bash
nix-swarm cluster credentials --source . --yes
```

`secrets/*.cookie` and `secrets/*.key` are ignored by Git and excluded from package sources. For established environments, prefer sops-nix/agenix or systemd encrypted credentials.

Never put secrets in `services.nix-swarm.services.<name>.settings`; that data is copied into the world-readable Nix store.

## SSH and operator authorization

Deploy and query commands require normal host-key verification and batch authentication. Add existing users to the query-socket group declaratively:

```nix
services.nix-swarm.operatorUsers = [ "alice" ];
```

Then use `--ssh-host alice@node-a`. Query operations are logged in the agent's journal. TUI actions cannot change desired state, services, or hosts.

## Failure safety

- configuration, intervals, replicas, unit names, query sizes, and log counts are bounded
- agents refuse destructive reconciliation while live config digests differ
- rollout batches stop on build, activation, membership, peer reachability, placement, or updated-node health failure; the final batch also requires config consistency and every owned unit to be healthy
- systemd applies memory, task, file-descriptor, namespace, capability, filesystem, and device restrictions

## Cookie rotation

Block BEAM ports, replace the cookie on every peer, and restart the agents as one maintenance operation. Mixed cookies partition the cluster; separate partitions can temporarily run duplicate stateless replicas.
