# Configuration reference

All desired state is under `services.nix-swarm` in Nix.

## Agent options

| Option | Default | Purpose |
|---|---:|---|
| `enable` | `false` | Enable the module |
| `package` | cluster package | Agent package |
| `nodeName` | required | Distributed-Erlang node name |
| `cookieFile` | required | Absolute, out-of-store agent cookie path |
| `enableDaemon` | `true` | Run `nix-swarmd` |
| `epmdPort` | `4369` | EPMD port |
| `distributionPort` | `4370` | Fixed BEAM distribution port |
| `openFirewall` | `false` | Open both peer ports |
| `firewallInterfaces` | `[]` | Required private interfaces when opening ports |
| `operatorGroup` | `nix-swarm-operators` | Read-only query-socket group |
| `operatorUsers` | `[]` | Existing SSH users added to that group |
| `extraManagedUnits` | `[]` | Exact temporary unit allowlist for migrations |
| `onFailureUnits` | `[]` | Native systemd `OnFailure=` targets |
| `resourceLimits.memoryMax` | `512M` | Agent `MemoryMax` |
| `resourceLimits.tasksMax` | `512` | Agent `TasksMax` |

`openFirewall = true` is rejected unless `firewallInterfaces` is non-empty.

## Nodes

```nix
services.nix-swarm = {
  peers = [ "nix-swarm@node-a" "nix-swarm@node-b" ];

  nodes."nix-swarm@node-a" = {
    labels = [ "apps" "ssd" ];
    availability = "active"; # "active", "draining", or "maintenance"
    deployHost = "root@node-a";
    nixosConfiguration = "node-a";
  };
};
```

Every peer needs node metadata. Only stabilized `up`/`suspect`, active nodes are eligible for placement. `draining` removes placement; `maintenance` also removes the node from deploy and autoscaling membership gates.

## Services

```nix
services.nix-swarm.services.api = {
  replicas = 2;
  maxReplicasPerNode = 2;
  unitTemplate = "api@%{slot}.service";
  constraints = [ "apps" ];
  allowedNodes = [ "nix-swarm@node-a" "nix-swarm@node-b" ];
  preferredNodes = [ "nix-swarm@node-a" ];
  readiness = { timeoutSec = 120; stableSamples = 2; };
  autoscaling = {
    enable = true;
    minReplicas = 2;
    maxReplicas = 8;
    cpuTargetPercent = 65;
    sampleWindowSec = 60;
    scaleUpCooldownSec = 30;
    scaleDownCooldownSec = 300;
    maxStep = 1;
  };
  settings.port = 8080;
};
```

| Field | Default | Meaning |
|---|---:|---|
| `replicas` | `1` | Slots, from `0` through `128`; zero disables |
| `maxReplicasPerNode` | `null` | Optional per-node service capacity |
| `unitTemplate` | derived | One replica: `%{service}.service`; multiple: `%{service}@%{slot}.service` |
| `constraints` | `[]` | Required node labels |
| `allowedNodes` | `[]` | Hard node allowlist |
| `preferredNodes` | `[]` | Deterministic soft preference |
| `readiness` | systemd, 120s, 2 samples | Strict systemd readiness policy |
| `autoscaling` | disabled | CPU-only scaling bounds and stabilization policy |
| `healthcheck` | `null` | Display-only compatibility field; shell is never executed |
| `settings` | `{}` | Public string/int/bool metadata for TUI and ingress; never secrets |

Nix-Swarm manages only the rendered unit names. Define those units in normal NixOS modules and let systemd own dependencies, credentials, readiness, restarts, cgroups, and logs.

## Runtime

```nix
services.nix-swarm.runtime = {
  connectIntervalMs = 500;
  reconcileIntervalMs = 5000;
  autoscaleIntervalMs = 10000;
  failureGraceMs = 10000;
  recoveryStabilizationMs = 30000;
  commandTimeoutMs = 5000;
  generation = "production";
};
```

Intervals must be `100-3600000ms`; `commandTimeoutMs` is capped at `300000ms`. `failureGraceMs` prevents transient disconnects from moving work, while `recoveryStabilizationMs` prevents a flapping machine from immediately receiving it again.

## Deployment manifest

Cluster flakes export evaluated deployment metadata; the CLI does not parse Nix source text:

```nix
outputs = inputs@{ self, nixpkgs, nix-swarm, ... }:
let
  nixosConfigurations = { /* normal nixosSystem outputs */ };
in {
  inherit nixosConfigurations;
  nixSwarm.deploymentManifest =
    nix-swarm.lib.mkDeploymentManifest nixosConfigurations;
};
```

`services.nix-swarm.deployment` defines `healthTimeoutSec` (120), `stableSamples` (2), and `autoRollback` (true).

## Ingress

Ingress sites are compatibility metadata only. Configure nginx, HAProxy, or another NixOS load balancer explicitly; Nix-Swarm does not synthesize backends or implement a routing mesh.
