# Alerting

How Nix-Swarm failures surface, how to get notified, and how to triage
with journald. This covers the v1.0 failure model: unit-level supervision
and deployment health gates. There is no in-product notification bus;
alerting is a small amount of standard systemd glue on each node.

## What can fail, and how it surfaces

| Failure | Detection | Default behavior |
|---|---|---|
| Agent process crash/hang | systemd `Type=notify` + watchdog | see [Watchdog contract](#watchdog-contract) |
| Agent repeated crash loop | systemd start-limit | unit enters `failed` after `StartLimitBurst=10` within `StartLimitIntervalSec=120` |
| Workload unit fails | its own restart policy (`Restart=on-failure`, as declared in the Nix config) | systemd keeps restarting; the reconciler reports drift |
| Deployment fails | rollout health gate during `cluster apply` / `cluster rollback` | apply aborts, auto-rolls-back attempted hosts, and reports `rollback_status` |
| Node unreachable / partitioned | membership timers (`net_ticktime 10`, reconnect backoff) | leaderless: both sides keep serving; duplicates converge on heal (see [Backup and recovery](BACKUP_RECOVERY.md)) |

Only the first three are local systemd events suitable for `OnFailure=`
wiring. Deploy failures are visible to the operator who ran the command;
partition events are **not alerted** by design — the system is built to
serve through them, and the reconciler heals placement afterwards.

## systemd `OnFailure=` wiring

The NixOS module exposes exactly one hook: `onFailureUnits`, a list of
units started whenever **`nix-swarmd` fails** (after the restart policy
gives up). A unit that is merely restarting does not trigger it; only a
unit in the `failed` state does.

Use a **template instance** so the alert knows which unit failed: systemd
expands `%n` in `OnFailure=` to the failing unit's own name, so
`alert@%n.service` is instantiated per failure and the template's `%i` is
the failed unit name.

```nix
# node configuration.nix
{ config, pkgs, ... }:
let
  alertUrl = "https://ntfy.example.com/nix-swarm"; # or ntfy.sh/<topic>
  alertScript = pkgs.writeShellScript "nix-swarm-failure-alert" ''
    ${pkgs.curl}/bin/curl --fail --silent --show-error \
      -H "Title: ${config.networking.hostName}: $1 failed" \
      -d "$1 entered the failed state on ${config.networking.hostName}." \
      "${alertUrl}"
  '';
in {
  services.nix-swarm.onFailureUnits = [ "nix-swarm-failure-alert@%n.service" ];

  systemd.services."nix-swarm-failure-alert@" = {
    description = "Alert when the Nix-Swarm agent fails";
    serviceConfig = {
      Type = "oneshot";
      # %i is the failed unit's name (the OnFailure= %n expansion)
      ExecStart = "${alertScript} %i";
    };
  };
}
```

Notes:

- Define the alert unit as an ordinary NixOS unit in your own config; the
  module only references it by name and never generates it.
- Prefer ntfy or a generic webhook endpoint over mail: one `curl` call, no
  mail infrastructure, and the topic can fan out to phone push, email, or
  chat.
- Rate-limit on the receiver side (ntfy/alertmanager-style dedupe). A crash
  loop that exhausts the start limit fires once per entry into `failed`,
  which is already throttled by `RestartSec=2` plus the start-limit window.

## Watchdog contract

`nix-swarmd` runs as `Type=notify` with `WatchdogSec=30s`. The agent's
watchdog process sends an sd_notify ping **every 15 seconds**. If systemd
sees no ping for 30 seconds (agent VM stall, deadlock, wedged BEAM), it
kills the service; `Restart=on-failure` with `RestartSec=2` brings it back.
Only when restarts exhaust the start limit does the unit go `failed` and
`OnFailure=` fire — so a transient hang alerts only if it does not
self-heal.

Observe the contract directly:

```bash
systemctl show nix-swarmd -p WatchdogUSec,Restart,StartLimitBurst
journalctl -u nix-swarmd -n 200 --no-pager
```

## Triage with journald

Local, per-node, no extra tooling:

```bash
# agent problems
journalctl -u nix-swarmd -f                          # follow
journalctl -u nix-swarmd -p err -n 50                # errors only

# a managed workload unit (name from `nix-swarm cluster status` / config)
journalctl -u 'demo@web-a.service' -n 200
journalctl -u 'demo@*.service' --since today

# boot-time and OOM context
journalctl -k -b -p warning
journalctl -u nix-swarmd -n 200 | grep -i -E 'kill|oom|watchdog'
```

The operator query surface also tails logs read-only over SSH
(`nix-swarm service logs --name NAME --target NODE`); journald on
the node is the ground truth when those are unavailable.

## Periodic health check (recommended)

`OnFailure=` fires only when the agent fails. For silent drift — a node
partitioned long-term, unit count off, credential skew — run the read-only
operator checks on a timer from your control host (the machine where you
installed the operator package, so `nix-swarm` is on `PATH`) and alert on
non-zero output:

```nix
# control-host configuration.nix
{ pkgs, ... }: {
  systemd.timers.nix-swarm-healthcheck = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "hourly"; Persistent = true; };
  };

  systemd.services.nix-swarm-healthcheck = {
    serviceConfig.Type = "oneshot";
    script = ''
      if ! out=$(nix-swarm cluster status --json 2>&1); then
        ${pkgs.curl}/bin/curl --fail --silent --show-error \
          -H "Title: nix-swarm health check failed" \
          -d "cluster status exited non-zero: $out" \
          "https://ntfy.example.com/nix-swarm"
      fi
    '';
  };
}
```

`nix-swarm cluster doctor` from the same host reports actionable classes
(SSH keys, architecture, credential mismatch, config digest drift) and is a
good companion check.

## What alerting does not cover

- **Partitions and duplicates** — accepted by design; see
  [Backup and recovery](BACKUP_RECOVERY.md).
- **Workload unit failures** — they restart per policy and the reconciler
  reports drift; add per-unit `OnFailure=` in your own NixOS units if a
  workload must page a human.
- **Deploy-time failures** — surfaced to the operator running the command
  (`rollback_status=...` in the failure report); alert on your CI/deploy
  runner if applies are unattended.
