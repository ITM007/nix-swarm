# Prepared Nix-Swarm starter

This starter is a small **NixOS configuration example** for one machine that
has already been prepared by its owner. Nix-Swarm starts at SSH preflight: it
does not install NixOS, partition disks, configure boot, or choose storage.

## Prepare the machine first

Users own the installation method, disk layout, hardware configuration, boot,
firmware, and network bring-up. Before handoff, verify:

- the machine is already running NixOS;
- the SSH host key is reviewed and pinned and public-key authentication works;
- root SSH or passwordless noninteractive deployment privilege is available;
- architecture and disk space meet the closure and rollback requirements;
- peers reach one another on the trusted private network;
- the deploy host, node name, hardware configuration, and `system.stateVersion`
  are declared in the `.nix` inventory.

Replace `machines/hardware-configuration.nix` with the real hardware
configuration from the prepared host. Replace the deployment SSH public key in
`machines/node-a.nix` before evaluating or applying the configuration.

## Bootstrap and apply

From this directory, Nix-Swarm starts at SSH/preflight/bootstrap:

```bash
nix flake check
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
```

`cluster apply` is the first Nix-Swarm mutation. It enrolls only a missing
shared cookie when authorized, activates the complete NixOS configuration, and
verifies convergence. The cookie is never stored in the Nix store; prefer
sops-nix, agenix, or systemd credentials for established deployments.

## Example service

`services/example-web.nix` is the only workload example: a single bounded
systemd service. It is declared in `machines/node-a.nix` and enabled by the
`example-web` service entry in `cluster.nix`. Copy that `.nix` file when adding
a workload; Nix-Swarm does not maintain a second desired-state format.

The flake uses the project's hardened NixOS module as a secure default. It is
a service baseline, not a machine-installation or hardware matrix. Native
machine preparation and bare-metal acceptance remain user-owned and are not
required to claim the Nix-Swarm release boundary.
