# Hardened Nix-Swarm starter

This starter is a hardened **NixOS configuration example** for a machine that
has already been prepared by its owner. Nix-Swarm does not install NixOS,
partition disks, or operate `nixos-anywhere` or Disko.

## Prepare the machine first

Users own the installation method, disk layout, hardware configuration, boot,
firmware, and network bring-up. `nixos-anywhere` and Disko may be used as
optional, user-owned preparation examples, but they are not supported Nix-Swarm
automation or release gates. Review their destructive behavior independently.

Before handoff, verify:

- the machine is already running NixOS;
- the SSH host key is reviewed and pinned and public-key authentication works;
- root SSH or passwordless noninteractive deployment privilege is available;
- architecture and disk space meet the closure and rollback requirements;
- peers reach one another on the trusted private network;
- the deploy host, node name, hardware configuration, and `system.stateVersion`
  are declared in the `.nix` inventory.

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

## Hardened baseline

The profile provides:

- public-key-only SSH with root password login disabled;
- no SSH agent, X11, SFTP, or unrestricted TCP forwarding;
- default-deny firewall behavior;
- BEAM ports only on the declared private interface;
- unprivileged, resource-bounded `nix-swarmd`;
- persistent bounded journald;
- time synchronization and conservative Nix garbage collection;
- no desktop, compiler toolchain, Git checkout, or unrelated daemon.

Docker and Nix evaluation checks validate the profile contract. Native machine
installation and bare-metal acceptance remain user-owned preparation and are
not required to claim the Nix-Swarm release boundary.
