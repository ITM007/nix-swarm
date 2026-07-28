# Bootstrap contract

Nix-Swarm starts with a machine that is **already running NixOS**. Machine
installation and storage layout are user-owned preparation, not Nix-Swarm
release gates. The product boundary is:

```text
prepare NixOS → declare the node in .nix → preflight → plan → cluster apply
```

## Required before Nix-Swarm acts

Prepare and verify every target before running the operator:

- SSH is reachable from the deployment host and the host key is reviewed and
  pinned;
- public-key authentication works noninteractively;
- the deployment account is root or has passwordless noninteractive privilege;
- the target architecture is supported and the deployment host or a remote
  builder can build it;
- enough disk space exists for the incoming Nix closure and a rollback
  generation;
- peers can reach one another on the configured trusted private network;
- the `.nix` inventory identifies the node, deployment host, and complete
  `nixosConfigurations.<name>` output, including hardware and filesystem
  configuration;
- `system.stateVersion` matches the machine's original NixOS release.

The target does not need Nix-Swarm, `nix-swarmd`, a Git checkout, or Mix tooling.
Nix-Swarm's preflight checks the boundary and reports blockers before mutation.

## First Nix-Swarm mutation

After preparation, review the plan and run the explicit apply command:

```bash
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
```

`cluster apply` is the first Nix-Swarm mutation. It builds closures before
activation, enrolls only a missing credential when authorized, activates the
NixOS configuration, and verifies readiness and convergence. It never checks out
source on a target and it does not create a second desired-state format.

## Optional user-owned installation examples

Users may prepare a machine with their preferred installer, including
`nixos-anywhere` and Disko, but those tools are not implemented, operated, or
release-gated by Nix-Swarm. Review their destructive storage behavior and
security implications independently. Once the machine is running NixOS, return
to the SSH/preflight/bootstrap/apply contract above.
