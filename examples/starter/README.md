# Hardened Nix-Swarm starter

This starter is a minimal, hardened NixOS profile for provisioning a disposable
or dedicated x86_64 machine with `nixos-anywhere` and Disko.

## Before provisioning

Review and replace every machine-specific value in:

```text
machines/node-c/default.nix
machines/node-c/disko.nix
```

You must set:

- a real deployment SSH public key;
- the target's stable `/dev/disk/by-id/...` device;
- hostname and `nix-swarm@...` node name;
- the target's original `system.stateVersion`;
- the private WireGuard/Tailscale interface used for BEAM traffic;
- the deploy host and cluster inventory metadata.

The Disko target is destructive. It erases the explicitly selected disk. Never
use `/dev/sda` or `/dev/nvme0n1` by guesswork.

The starter uses one supported baseline: x86_64 Linux, UEFI/GPT, one ext4 root
partition, and a 1 GiB EFI system partition. Encryption, RAID, Btrfs, Secure
Boot, TPM enrollment, and cloud-specific storage are separate variants and are
not silently enabled by this example.

## Provision and join

After reviewing the complete flake:

```bash
nix flake check
nixos-anywhere --flake .#node-c root@node-c
nix-swarm cluster apply --source .
```

`nixos-anywhere` installs NixOS and the hardened Nix-Swarm profile. The follow-up
`cluster apply` enrolls a missing shared cookie when authorized, activates the
complete cluster configuration, and verifies convergence.

The cookie is never stored in the Nix store. Prefer sops-nix, agenix, or systemd
credentials for established deployments. The built-in enrollment path only
installs a missing cookie and refuses to overwrite a different existing cookie.

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

Docker and Nix evaluation checks validate the profile contract. A disposable
native target must still be used before advertising a production bare-metal
provisioning result.
