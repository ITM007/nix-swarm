# Configuration reference

Nix-Swarm configuration is declared through the NixOS module under `services.nix-swarm`.

## Runtime options

| Option | Type | Default | Notes |
|---|---|---:|---|
| `enable` | bool | `false` | Enables `nix-swarmd` on the node |
| `package` | package | local package | Package exposing `bin/nix-swarm` and `bin/nix-swarmd` |
| `nodeName` | string | required | Distributed Erlang node name, for example `nix-swarm@example-node-a.local` |
| `cookieFile` | string | required | Absolute path to the shared Erlang cookie |
| `epmdPort` | port | `4369` | EPMD discovery port |
| `distributionPort` | port | `4370` | Fixed Erlang distribution port |
| `openFirewall` | bool | `false` | Opens EPMD and distribution ports |
| `firewallInterfaces` | list(string) | `[]` | Restricts opened ports to specific interfaces |

## Cluster topology

`services.nix-swarm.peers` is the complete list of configured Erlang node names. Only configured peers participate in placement.

`services.nix-swarm.nodes` stores node metadata keyed by node name:

```nix
services.nix-swarm.nodes."nix-swarm@example-node-a.local" = {
  labels = [ "gitea" "ingress" ];
  deployHost = "example-node-a.local";
};
```

`labels` are used by service constraints. `deployHost` is the SSH target used by update/apply workflows.

## Services

Services are declared under `services.nix-swarm.services.<name>`:

```nix
services.nix-swarm.services.gitea = {
  replicas = 2;
  unitTemplate = "gitea@%{slot}.service";
  constraints = [ "gitea" ];
  preferredNodes = [ "nix-swarm@example-node-a.local" ];
  settings = {
    domain = "gitea.example.internal";
    httpPort = 3003;
  };
};
```

| Field | Type | Default | Notes |
|---|---|---:|---|
| `replicas` | int | `1` | Desired replica slots |
| `unitTemplate` | string or null | derived | `%{service}` and `%{slot}` are expanded |
| `constraints` | list(string) | `[]` | All labels must be present on a node |
| `preferredNodes` | list(string) | `[]` | Biases deterministic placement |
| `healthcheck` | string or null | `null` | Reserved for future health checks |
| `settings` | attrset | `{}` | Runtime metadata surfaced to the API/TUI |

Placement is deterministic. If there are more replicas than eligible live nodes, slots wrap around and multiple replicas can land on the same node. If no eligible live node exists, slots are unowned and reported through placement diagnostics.

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
