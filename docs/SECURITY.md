# Security model

Nix-Swarm uses distributed Erlang for node-to-node and operator-to-node RPC. Authentication is based on a shared Erlang cookie. Nix-Swarm does not add TLS around distributed Erlang.

Use Nix-Swarm only on trusted networks or over your own private overlay/VPN.

## Cookie handling

Generate a strong cookie once and install it outside the Nix store:

```bash
tr -dc 'A-Za-z0-9_.-' </dev/urandom | head -c 48 > nix-swarm.cookie
install -m 600 -o root -g root nix-swarm.cookie /etc/nixos/nix-swarm/secrets/nix-swarm.cookie
```

Prefer a local cookie file under `~/.config/nix-swarm/secrets/` or `NIX_SWARM_COOKIE_FILE` for operator launches:

```bash
install -Dm600 /path/to/nix-swarm.cookie ~/.config/nix-swarm/secrets/swarm.cookie
swarm
```

Avoid `--cookie` except for temporary local testing because command-line arguments can be visible in process listings.

If the packaged `swarm` wrapper cannot find a real cookie, it exports a local placeholder so the release runtime can still start far enough to print help text and higher-level errors. That placeholder is **not** a valid cluster secret and will not let the operator authenticate to real nodes.

## Firewalling

Restrict EPMD and distributed Erlang to cluster/operator networks:

```nix
services.nix-swarm = {
  openFirewall = true;
  firewallInterfaces = [ "eth0" ];
};
```

If `firewallInterfaces = []`, the module opens the ports on all interfaces. That is convenient for testing but not recommended for exposed hosts.

## SSH host key trust during deploy/apply

Built-in apply and update workflows use `StrictHostKeyChecking=accept-new` for first contact with a deploy host. That avoids interactive SSH prompts during unattended runs, but it means the first connection still depends on the network path being trustworthy.

For production clusters, pre-populate `known_hosts` (or otherwise distribute trusted host keys) before using automated deploy/apply workflows across new machines.

## Compromise model

Any actor with the Erlang cookie and network access to the distribution port can perform remote Erlang operations. Treat the cookie like a root-equivalent cluster secret.

If the cookie leaks:

1. Block EPMD/distribution ports at the firewall.
2. Generate a new cookie.
3. Replace the cookie file on every node and operator workstation.
4. Restart `nix-swarmd` on every node.
