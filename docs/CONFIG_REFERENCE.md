# Configuration reference

Nix-Swarm configuration is declared through the NixOS module under `services.nix-swarm`.

## Runtime options

| Option | Type | Default | Notes |
|---|---|---:|---|
| `enable` | bool | `false` | Enables `nix-swarmd` on the node |
| `package` | package | local compatibility package | Package exposing `bin/nix-swarmd`; release flakes also expose a dedicated `packages.<system>.cluster` output, while the compatibility package still includes `bin/swarm` and `bin/nix-swarm` |
| `nodeName` | string | required | Distributed Erlang node name, for example `nix-swarm@example-node-a.local` |
| `cookieFile` | string | required | Absolute path to the shared Erlang cookie |
| `epmdPort` | port | `4369` | EPMD discovery port |
| `distributionPort` | port | `4370` | Fixed Erlang distribution port |
| `openFirewall` | bool | `false` | Opens EPMD and distribution ports |
| `firewallInterfaces` | list(string) | `[]` | Restricts opened ports to specific interfaces |

## Cluster topology

`services.nix-swarm.peers` is the complete list of configured Erlang node names. Only configured peers participate in placement. Every managed node must set a `nodeName` that appears in `peers`.

`services.nix-swarm.nodes` stores node metadata keyed by node name:

```nix
services.nix-swarm.nodes."nix-swarm@example-node-a.local" = {
  labels = [ "gitea" "ingress" ];
  deployHost = "example-node-a.local";
};
```

Every peer must have a matching `nodes.<peer>` entry with a non-empty `deployHost`. `labels` may be empty; unconstrained services can still run on unlabeled nodes. `deployHost` is the SSH target used by update/apply workflows.

## Services

Services are declared under `services.nix-swarm.services.<name>`:

```nix
services.nix-swarm.services.gitea = {
  replicas = 2;
  unitTemplate = "gitea@%{slot}.service";
  constraints = [ "gitea" ];
  allowedNodes = [ "nix-swarm@example-node-a.local" "nix-swarm@example-node-b.local" ];
  preferredNodes = [ "nix-swarm@example-node-a.local" ];
  settings = {
    domain = "gitea.example.internal";
    httpPort = 3003;
  };
};
```

| Field | Type | Default | Notes |
|---|---|---:|---|
| `replicas` | non-negative int | `1` | Desired replica slots; `0` disables the service |
| `unitTemplate` | string or null | derived | `%{service}` and `%{slot}` are expanded |
| `constraints` | list(string) | `[]` | All labels must be present on a node |
| `allowedNodes` | list(string) | `[]` | Optional hard allowlist of peer node names; empty means no hard node restriction |
| `preferredNodes` | list(string) | `[]` | Soft ordering bias among otherwise eligible nodes |
| `healthcheck` | string or null | `null` | Reserved/display-only in v1; it does not drive restarts, failover, or placement |
| `settings` | flat attrset of string/int/bool | `{}` | Runtime metadata surfaced to the API/TUI |

Placement is deterministic from shared config plus currently live configured peers. A node is eligible only when it is in `allowedNodes` if that list is non-empty and it has all labels in `constraints`. `preferredNodes` only orders eligible nodes; it is not pinning.

If there are more replicas than eligible live nodes, slots wrap around and multiple replicas can land on the same node. Multi-replica services must therefore use slot-addressable systemd units and slot-distinct ports when exposing ports. The default multi-replica unit template is `%{service}@%{slot}.service`, which expects a backing NixOS/systemd template unit such as `systemd.services."example@"`.

`replicas = 0` is the declarative disable state. Nix-Swarm schedules no slots and will best-effort stop previously owned local units while the daemon still remembers them; durable prevention comes from the Nix config applied to the host.

If no eligible live node exists, slots are unowned and reported through placement diagnostics. Metrics are visibility-only in v1 and do not influence placement or rebalancing.

## Operator actions and source of truth

Nix remains the durable source of truth. TUI service start/stop actions are temporary in-memory overrides and do not survive daemon restarts. The TUI supports service-wide actions from service-oriented views and machine-local service actions from the Machines view when both a machine and service are selected.

The built-in apply/update workflow edits a local working tree (`~/.config/nix-swarm` or `--source`) and applies it outward over SSH with sequential `nixos-rebuild switch` runs. Rebuild failures are reported clearly; automatic rollback is intentionally out of scope for v1.

## Runtime tuning

```nix
services.nix-swarm.runtime = {
  connectIntervalMs = 500;
  reconcileIntervalMs = 500;
  commandTimeoutMs = 5000;
  generation = "nixos";
};
```

`commandTimeoutMs` bounds local `systemctl`, `journalctl`, and metrics commands so a stuck system command does not block status or reconciliation indefinitely.
