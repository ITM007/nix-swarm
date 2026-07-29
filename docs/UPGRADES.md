# Upgrades

Nix-Swarm upgrades are reviewed Nix changes applied explicitly through the
normal plan/apply workflow.

## Upgrade the cluster

From the repository checkout:

```bash
nix-swarm cluster upgrade --source . --yes
```

This updates the `nix-swarm` flake input, validates the resulting closures, and
performs the normal sequential health-gated rollout. Review and commit the
resulting `flake.lock` change afterward. If you want to inspect changes first,
update the input and lock file manually, then run `cluster plan` before apply.

`cluster upgrade` is a mutation command and requires `--yes`. It does not skip
Nix evaluation, closure validation, preflight, credential checks, protocol
checks, health gates, or rollback behavior.

## Upgrade application and Caddy configuration

Application units, Caddy configuration, routes, TLS policy, and backend
candidates are ordinary user-owned NixOS configuration. Edit those `.nix`
modules, review the diff, then run:

```bash
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
```

Nix-Swarm deploys the resulting NixOS generation. It never rewrites a Caddyfile,
creates a generated routing file, or calls the Caddy Admin API.

## Failure behavior

All selected closures are built before mutation. Deployment is sequential and
uses the fixed readiness gate. If activation or readiness fails, attempted hosts
are rolled back to their previous NixOS generation. A failed Caddy activation
therefore fails the ordinary host rollout; no special Caddy rollback path is
needed.

If flake evaluation or build validation fails, no host is mutated.

## Rollback

```bash
nix-swarm cluster rollback --source . --yes
```

Rollback activates each target's previous native NixOS generation and runs the
same health gate. It does not restore arbitrary mutable files, Caddy certificate
state, or application data. Databases and other stateful workloads require
their own backup and rollback procedure.

## Operator package

Update only the local operator profile with:

```bash
nix profile upgrade operator
```

Keep the operator and target protocol versions compatible during rolling
upgrades. The read-only status projection reports desired/observed generations,
releases, digests, drift, and synchronization state. Git and evaluated Nix
remain authoritative.
