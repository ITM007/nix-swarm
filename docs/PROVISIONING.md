# Preparing a NixOS target

Nix-Swarm assumes the target is **already running NixOS**. Users own machine
installation, disk layout, hardware discovery, boot, firmware, encryption,
network bring-up, and storage validation. None of those are Nix-Swarm product
or release requirements.

## User-owned preparation

Prepare the machine with the installer and storage tooling appropriate for the
site. `nixos-anywhere` and Disko may be used as optional examples, but they are
not Nix-Swarm automation and are not release-gating. Review all destructive
commands, especially the selected disk, independently.

Before handing the target to Nix-Swarm, verify:

- NixOS is installed and boots successfully;
- SSH host identity is reviewed and pinned;
- public-key SSH authentication works;
- root SSH or passwordless noninteractive remote sudo is available;
- architecture and Nix builder support are compatible;
- free disk space covers the incoming closure and a rollback generation;
- peers are reachable on the configured trusted private network;
- the `.nix` inventory contains the node, deployment host, hardware/filesystem
  configuration, and original `system.stateVersion`.

## Handoff to Nix-Swarm

From the deployment host, begin at preflight and use the explicit mutation:

```bash
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
```

`cluster apply` is the first Nix-Swarm mutation. It builds every selected
closure before activation, enrolls only a missing credential, activates the
NixOS configuration, and verifies readiness and convergence. A different
existing remote cookie is an error and is never overwritten automatically.

## Scope boundary

Nix-Swarm owns SSH/preflight/bootstrap/apply onward: Nix closure deployment,
credential enrollment, service activation, cluster membership, health-gated
rollout, convergence, and rollback of attempted hosts. It does not partition a
disk, install an operating system, generate hardware configuration, or validate
machine-specific storage and firmware.
