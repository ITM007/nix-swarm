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
| Fixed `MemoryMax` | `512M` | Agent systemd memory limit |
| Fixed `TasksMax` | `512` | Agent systemd task limit |

`openFirewall = true` is rejected unless `firewallInterfaces` is non-empty.

## Nodes

```nix
services.nix-swarm = {
  peers = [ "nix-swarm@node-a" "nix-swarm@node-b" ];

  nodes."nix-swarm@node-a" = {
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
  unitTemplate = "api@%{slot}.service";
  allowedNodes = [ "nix-swarm@node-a" "nix-swarm@node-b" ];
  autoscaling = {
    enable = true;
    minReplicas = 2;
    maxReplicas = 8;
    cpuTargetPercent = 70;
    memoryTargetPercent = 80;
  };
};
```

| Field | Default | Meaning |
|---|---:|---|
| `replicas` | `1` | Slots, from `0` through `128`; zero disables |
| `unitTemplate` | derived | One replica: `%{service}.service`; multiple: `%{service}@%{slot}.service` |
| `allowedNodes` | `[]` | Hard node allowlist |
| `autoscaling` | disabled | CPU-and-memory bounds; fixed policy uses finite systemd `MemoryMax` |

Nix-Swarm manages only the rendered unit names. Define those units in normal NixOS modules and let systemd own dependencies, credentials, readiness, restarts, cgroups, and logs.

Memory utilization is `MemoryCurrent / MemoryMax` per service unit. If
`MemoryMax` is missing or unlimited, memory scaling is unavailable for that
unit and a diagnostic is reported; CPU scaling continues without guessing host
memory. Enabling autoscaling is the explicit assertion that concurrent
instances are safe.

## Internal policy

Readiness always waits up to 120 seconds and requires two healthy samples. Autoscaling samples over 60 seconds, evaluates every 10 seconds, uses 30/300 second up/down cooldowns, changes one replica per decision, and uses 70% scale-down hysteresis. These expert timings are not configuration options.

## Deployment manifest

Cluster flakes export evaluated deployment metadata; the CLI does not parse Nix source text:

```nix
outputs = inputs@{ self, nixpkgs, nix-swarm, ... }:
let
  nixosConfigurations = { /* normal nixosSystem outputs */ };
in {
  inherit nixosConfigurations;
  lib.nixSwarm.deploymentManifest =
    nix-swarm.lib.mkDeploymentManifest nixosConfigurations;
};
```

Deployment policy is internal and fixed: one host at a time, a 120-second
health gate with two consecutive healthy samples, and rollback attempted hosts
after every failure. There are no deployment rollout knobs in the Nix module
or manifest.

## Optional Caddy edge routing

Nix-Swarm does not provide an ingress controller or routing mesh. Users may
configure Caddy through the standard NixOS `services.caddy` module and manage
it as an ordinary Nix-Swarm service restricted to one edge node:

```nix
services.nix-swarm.services.caddy = {
  replicas = 1;
  unitTemplate = "caddy.service";
  allowedNodes = [ "nix-swarm@edge-a" ];
};
```

Keep the Caddy policy in a user-owned `.nix` module. List the finite candidate
backend endpoints and use Caddy active health checks to remove nodes whose
systemd service is not currently ready. Nix-Swarm never edits a Caddyfile,
calls the Caddy Admin API, or creates a second routing configuration.

Edit the Nix module and apply it normally:

```bash
nix-swarm cluster plan --source .
nix-swarm cluster apply --source . --yes
```

The first supported design uses one explicit edge node. DNS, router
forwarding, certificates, certificate storage, and edge-node failover remain
operator responsibilities. Do not use automatic backend movement for
single-writer or stateful services without application-owned coordination.

## Optional built-in proxy

The built-in BEAM edge is disabled by default. It is independent of the
Nix-Swarm control path and may be enabled when a small trusted-LAN deployment
needs static host/path routing without a separate Caddy or nginx service.

```nix
services.nix-swarm.proxy = {
  enable = false; # set true to render nix-swarm-proxy.service
  listen.port = 8080;
  openFirewall = false;
  firewallInterfaces = [ ];
  routes = { };
  oidc = {
    issuer = "";
    clientId = "";
    scope = "openid email profile";
  };
  clientSecretFile = null;
  sessionSecretFile = null;
};
```

When enabled, the module renders a secret-free Erlang-terms configuration and
`nix-swarm-proxy.service` with `User = nix-swarm`, `Group = operatorGroup`,
`Type = simple`, `Restart = on-failure`, and runtime role `proxy`. The service
uses `NIX_SWARM_PROXY_CONFIG_PATH` and `HOME=/run/nix-swarm-proxy`. Secret files
are external absolute paths, must not be under `/nix/store`, and are delivered
through systemd `LoadCredential` as `proxy-client-secret` and
`proxy-session-secret`; they are read from `$CREDENTIALS_DIRECTORY`.

### Proxy options

| Option | Default | Meaning |
|---|---:|---|
| `proxy.enable` | `false` | Render and start the optional proxy |
| `proxy.listen.port` | `8080` | Listening TCP port |
| `proxy.openFirewall` | `false` | Allow the port through the NixOS firewall |
| `proxy.firewallInterfaces` | `[]` | Named interfaces for the proxy port; required when opening the firewall |
| `proxy.routes` | `{}` | Attribute set of static routes keyed by safe route names |
| `proxy.oidc.issuer` | `""` | OIDC issuer URL for protected routes |
| `proxy.oidc.clientId` | `""` | OIDC client ID; required when any route uses OIDC |
| `proxy.oidc.scope` | `openid email profile` | OIDC scope sent to the provider |
| `proxy.clientSecretFile` | `null` | Absolute out-of-store client-secret file |
| `proxy.sessionSecretFile` | `null` | Absolute out-of-store session-secret file |

Each route supports `host`, `pathPrefix` (default `/`), `upstreams` (default
`[]`), `auth` (`public` or `oidc`, default `public`), and optional
`oidc.redirectBase` and `oidc.scope` overrides. An OIDC callback is served at
`<redirectBase>/__auth/callback`; register that exact URI with the provider.

The module rejects empty hosts, empty upstream lists, upstreams that are not
strict `^[A-Za-z0-9.-]+:[0-9]+$` host:port values, unsafe route names, OIDC
routes without a top-level client ID, secret paths that are relative or under
`/nix/store`, and `openFirewall = true` without named interfaces. It never
opens the proxy port globally. Plain HTTP is acceptable only on the trusted
private network; use Caddy/nginx for public TLS and ACME policy.
