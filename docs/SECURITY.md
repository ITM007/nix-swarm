# Security model

Nix-Swarm uses distributed Erlang for node-to-node and operator-to-node RPC. Authentication is based on a shared Erlang cookie. Nix-Swarm does not add TLS around distributed Erlang.

Use Nix-Swarm only on trusted networks or over your own private overlay/VPN.

## Cookie handling

Generate a strong cookie once and install it outside the Nix store:

```bash
tr -dc 'A-Za-z0-9_.-' </dev/urandom | head -c 48 > nix-swarm.cookie
install -m 600 -o root -g root nix-swarm.cookie /etc/nixos/nix-swarm/secrets/nix-swarm.cookie
```

Prefer `NIX_SWARM_COOKIE_FILE` for operator launches:

```bash
export NIX_SWARM_COOKIE_FILE=/path/to/nix-swarm.cookie
swarm --target nix-swarm@example-node-a.local
```

Avoid `--cookie` except for temporary local testing because command-line arguments can be visible in process listings.

## Firewalling

Restrict EPMD and distributed Erlang to cluster/operator networks:

```nix
services.nix-swarm = {
  openFirewall = true;
  firewallInterfaces = [ "eth0" ];
};
```

If `firewallInterfaces = []`, the module opens the ports on all interfaces. That is convenient for testing but not recommended for exposed hosts.

## Compromise model

Any actor with the Erlang cookie and network access to the distribution port can perform remote Erlang operations. Treat the cookie like a root-equivalent cluster secret.

If the cookie leaks:

1. Block EPMD/distribution ports at the firewall.
2. Generate a new cookie.
3. Replace the cookie file on every node and operator workstation.
4. Restart `nix-swarmd` on every node.
