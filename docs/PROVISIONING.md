# Nix-Swarm provisioning

## Supported starter profile

Nix-Swarm ships a minimal hardened starter under `examples/starter/` for an
explicitly selected x86_64 UEFI/GPT disk:

```text
examples/starter/
├── flake.nix
├── cluster.nix
├── disko/uefi-single-disk-ext4.nix
├── profiles/nix-swarm-node.nix
└── machines/node-c/
    ├── default.nix
    └── disko.nix
```

The profile is intended for a new or disposable machine. It does not guess the
disk, generate credentials in the Nix store, configure an overlay network, or
promise support for every storage/boot environment.

## Required review

Before running `nixos-anywhere`, replace and verify:

- `REPLACE_WITH_YOUR_DEPLOYMENT_PUBLIC_KEY`;
- `/dev/disk/by-id/REPLACE_WITH_TARGET_DISK`;
- hostname and node name;
- original `system.stateVersion`;
- deploy host;
- private WireGuard/Tailscale interface;
- architecture and inventory metadata.

The selected Disko device is erased. Use a stable `/dev/disk/by-id/` path and
review the `nixos-anywhere` target before confirming.

## Installation

From the starter directory:

```bash
nix flake check
nixos-anywhere --flake .#node-c root@node-c
```

The target installs NixOS with:

- hardened SSH settings;
- an unprivileged, bounded `nix-swarmd` systemd service;
- default-deny firewall settings;
- BEAM ports restricted to the declared private interface;
- persistent bounded journald;
- time synchronization;
- conservative Nix garbage collection;
- no source checkout or development toolchain.

The first boot may not start `nix-swarmd` until the shared cookie is available.
Use a declarative sops-nix/agenix/systemd credential setup when possible. For a
missing cookie, run the operator enrollment/apply workflow from the deployment
host:

```bash
nix-swarm cluster apply --source .
```

That workflow must install only a missing cookie; a different existing cookie is
an error and is never overwritten automatically.

## Scope

Disko and `nixos-anywhere` perform disk partitioning and OS installation. The
Nix-Swarm application begins once SSH reaches the installed NixOS system. Use
`nixos-anywhere`-specific variants for encryption, RAID, Secure Boot, TPM, or
cloud storage rather than expanding the minimal baseline implicitly.

Automated repository checks evaluate and build the starter. A disposable native
machine acceptance run is still required before calling bare-metal provisioning
production-ready.
