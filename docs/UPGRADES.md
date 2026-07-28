# Upgrades

Nix-Swarm upgrades are prepared as reviewed Nix changes and applied explicitly.

## Prepare

From the repository checkout:

```bash
nix-swarm cluster upgrade prepare --source .
```

Preparation:

1. updates only the `nix-swarm` flake input;
2. evaluates and builds the flake checks without writing another plan artifact;
3. leaves the resulting `flake.lock` change in the working tree for review;
4. reports whether the lock file changed.

No host is mutated by `cluster upgrade prepare`.

Review the resulting `.nix` changes and `flake.lock`, then use the common
mutation path:

```bash
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
```

`--yes` skips only the interactive confirmation. It does not skip evaluation,
closure validation, preflight, credential mismatch checks, protocol checks, or
health gates.

## Failure behavior

If flake validation fails, the exact previous `flake.lock` contents are
restored. The command fails closed and no deployment is attempted.

The legacy `cluster upgrade` command remains available for compatibility but
performs an immediate update-and-deploy operation. New workflows should use
`cluster upgrade prepare` followed by explicit `cluster apply`.

## Compatibility

Agents advertise a bounded read-only query protocol version and capabilities.
Rolling upgrades must keep the operator and target protocol versions
compatible. An incompatible target must be rejected before the first canary
mutation.

The read-only status projection reports:

- desired configuration digest;
- observed configuration digest;
- desired and observed generation;
- desired and observed release;
- drift fields and synchronization status.

These observations do not become a second desired-state database. Git and Nix
remain authoritative.
