# Preparing a NixOS target

This page is retained as an onboarding link for existing users. Nix-Swarm
starts with a machine that is **already running NixOS**; installation, disks,
hardware, firmware, and boot remain user-owned.

Before handoff, verify SSH host-key pinning, noninteractive authentication and
privilege, supported architecture, disk space for a closure and rollback
generation, trusted private-network reachability, and a complete `.nix`
inventory.

Continue with the canonical [bootstrap contract](BOOTSTRAP.md), then review the
plan and run `cluster apply --yes`. Nix-Swarm does not install NixOS or run
`nixos-anywhere` or Disko.
