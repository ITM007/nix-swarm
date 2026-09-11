# Stateful services

Nix-Swarm runs third-party stateful systemd apps safely on one node at a time:
you declare the app's state directories and a backup schedule, and Nix-Swarm
backs them up and, after an owner node fails, restores the latest snapshot
onto a surviving eligible node **before** starting the unit there.

## What nix-swarm truly requires

Running a cluster needs only:

1. NixOS with systemd (lifecycle, hardening, credentials, logs);
2. peers that can reach each other's BEAM distribution ports
   (EPMD 4369 and the distribution port 4370) — on your LAN by default, or
   through an encrypted mesh when peers span networks;
3. the shared cluster cookie (`cluster credentials rotate` installs it).

Everything else this document mentions is optional.

## Optionality table

| Component | Role | Needed when | Documented default example |
|---|---|---|---|
| Overlay / mesh | carries BEAM peer traffic off the LAN | peers are on different networks or behind NAT | NetBird (`netbird0`) — see your firewall `firewallInterfaces` |
| Backup target | stores borg repositories | a service declares `state.backup` | Garage (S3-compatible); any borg-compatible repo works |
| Reverse proxy | name/TLS/health-checked routing to app ports | you want domain + HTTPS access to apps | Caddy, see `docs/INGRESS.md`; no edge is needed for LAN/SSH-tunnel use |

No component is rendered unless you opt in: a service without a `state.backup`
block gets no backup units, and the mesh/proxy are user-owned NixOS
configuration, never module dependencies.

## State contract

A stateful service is declared like any other, plus a `state` block:

```nix
services.nix-swarm.services.paperless = {
  unitTemplate = "paperless.service";
  replicas = 1;                              # enforced single-writer
  allowedNodes = [
    "nix-swarm@node-a"
    "nix-swarm@node-b"
    "nix-swarm@node-c"
  ];
  state = {
    dirs = [ "/var/lib/paperless" ];         # required: one or more dirs
    backup = {                               # optional; omitting disables backups
      schedule = "hourly";                   # systemd OnCalendar
      target = "ssh://borg@backup/./paperless"; # opaque borg repo URI
    };
    onPlacement.restore = "borg-latest";     # "none" when no backup
    autoHeal = false;                        # default false (manual heal)
    healGraceSec = 600;                      # default 10 minutes
  };
};
```

Semantics:

- `state.dirs` must be a non-empty list of absolute directories. The app
  writes only there; Nix-Swarm treats those paths as the unit's recoverable
  state.
- `backup.target` is an **opaque borg repository URI** — a local path, an SSH
  repo, or any S3-compatible endpoint (`s3:...`, with Garage as the worked
  example). Repository credentials are delivered to the backup unit via
  systemd `LoadCredential`, never stored in the repo or in Nix.
- `restore` defaults to `"borg-latest"` whenever `backup` is present and to
  `"none"` otherwise.
- Stateful services are **single-writer**: validation rejects `replicas > 1`
  (and autoscaling beyond 1) for any service with a `state` block. Two live
  copies of one state directory would diverge; the reconciler never starts a
  second owner.
- Use `restore = "borg-latest"` with the built-in Borg workflow. The
  `"litestream"` enum is reserved for a future restore implementation and is
  not a supported backup provider in this release.

## Recovery model

| Shape | Mechanism | RPO | RTO |
|---|---|---|---|
| Any app + `state.dirs` + `state.backup` (Tier 1) | borgmatic schedule → chosen repo | backup interval (default hourly) | minutes (restore size) |
| Any app + `state.dirs` without `state.backup` | no Nix-Swarm backup or restore | none | operator-defined |

- The reconciler **never auto-starts** a stateful unit on a node whose
  declared state directories are absent. Such a unit reports
  `:awaiting_heal` in `cluster status` — it is not running and will not start
  until an operator heals it.
- `cluster heal NAME --yes [--node NODE]` restores the latest Borg snapshot onto a
  live eligible node: every declared state directory is written to its own
  `<dir>.restore-tmp` and verified (present, non-empty, restore exit 0) before
  any directory is published. Each staging directory is then atomically moved
  into place. On a restore failure all staging directories are removed and
  existing targets are left untouched (fail closed).
- After the restore is verified the unit is started and checked per the
  deploy health policy.
- When the previous owner rejoins, deterministic placement keeps exactly one
  owner. The non-owner node's copy is stopped; if the owner's own state is
  absent it reports `:awaiting_heal` again instead of starting empty.

### Manual heal is the default

`autoHeal = false` is the default and automatic healing is not implemented in
this release: an operator runs `cluster heal` after
confirming the owner is down. Reboots and brief partitions must not race a
restore, which is why `healGraceSec` (default 600 s) exists — it is the
minimum downtime before an automatic heal would even be considered when
`autoHeal` is later enabled per service.

**Release decision: manual heal only.** `autoHeal` is parsed and validated, but
no code path triggers a heal automatically in this release. Every restore is operator-initiated via
`cluster heal NAME --yes [--node NODE]`; the reconciler's only automatic
actions remain holding the unit in `:awaiting_heal` (never starting it with
missing state) and stopping a stale copy when ownership moves.

## Consistency caveats

- Restore is per-directory, best-effort point-in-time. Apps whose state spans
  several directories (e.g. a database file plus uploaded files) may not get
  a perfectly consistent cut across directories from independent restores —
  the safe case is one consolidated state directory per app.
- Backup repositories are operator-owned. If the repository lives on the same
  storage as the cluster (e.g. Garage on a cluster node), keep an off-site
  copy — Nix-Swarm does not replicate backups.
- Tier 1 restore is bounded by backup cadence (RPO) and repository/restore
  speed (RTO). The default retention is 24 hourly / 7 daily / 4 weekly
  snapshots per repo.
