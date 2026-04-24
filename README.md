# Swarm

Swarm is a **TUI-first, leaderless NixOS orchestrator** for small clusters. Every node runs the same OTP runtime, computes the same placement from shared Nix config, and only starts or stops its own local systemd units.

Swarm is for **Nix + systemd + distributed Erlang**. It is **not** a container platform and **not** a storage orchestrator.

![Swarm dashboard](docs/screenshots/dashboard.svg)

![Swarm services view](docs/screenshots/services.svg)

## Features

- **Operator TUI** for dashboard, topology map, machines, services, logs, rollout, dry-run, and apply workflows
- **Declarative Nix config** split into cluster, machine, and service files
- **Leaderless failover** with no central scheduler
- **Systemd-native runtime** instead of containers
- **Cluster + per-machine/service metrics**
- **Built-in config editing** from the TUI, with your system editor and return-to-TUI flow

## Add the release to a NixOS system

### Operator workstation

Add Swarm as a flake input and install the packaged `swarm` binary:

```nix
{
  inputs.swarm.url = "github:ITM007/swarm/v0.1.0";

  outputs = { self, nixpkgs, swarm, ... }: {
    nixosConfigurations.operator = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ({ pkgs, ... }: {
          environment.systemPackages = [
            swarm.packages.${pkgs.system}.default
          ];
        })
      ];
    };
  };
}
```

If your workstation is not itself a managed Swarm node, export the shared cookie once before launching:

```bash
export SWARM_COOKIE_FILE=/path/to/swarm.cookie
swarm --target swarm@192.168.1.226
```

### Managed cluster node

Import the module and point `services.swarm.package` at the release package:

```nix
{ inputs, pkgs, ... }:
{
  imports = [
    inputs.swarm.nixosModules.default
    ./cluster/cluster.nix
  ];

  services.swarm = {
    enable = true;
    package = inputs.swarm.packages.${pkgs.system}.default;
    nodeName = "swarm@192.168.1.226";
    cookieFile = "/etc/nixos/nix-swarm/secrets/swarm.cookie";
    openFirewall = true;
    firewallInterfaces = [ "eth0" ];
  };
}
```

## Launch

```bash
swarm --target swarm@192.168.1.226
```

Useful launch options:

- `--name control@192.168.1.10` if longname auto-detection picks the wrong local address
- `--source /path/to/checkout` to make apply/update/edit actions use a specific checkout
- `--cluster-file`, `--machines-dir`, `--services-dir`, `--remote-path`, `--nixos-dir` for path overrides

From a local checkout during development:

```bash
mix run -e 'Swarm.CLI.main(System.argv())' -- --target swarm@192.168.1.226
```

Core TUI actions:

- `tab` / `left` / `right`: switch views
- `j` / `k`: move selection
- `shift+h/j/k/l`: scroll wide or long panes
- `r`: refresh
- `x`: restart selected service
- `c`: reconcile cluster
- `y`: dry-run config rollout
- `p`: apply config rollout
- `u`: update running nodes
- `a` / `e` / `d`: add, edit, or delete machine/service config files

## Starter configs

### `machines/node-a.nix`

```nix
{ inputs, pkgs, ... }:
{
  imports = [
    inputs.swarm.nixosModules.default
    ../cluster/cluster.nix
  ];

  services.swarm = {
    enable = true;
    package = inputs.swarm.packages.${pkgs.system}.default;
    nodeName = "swarm@192.168.1.226";
    cookieFile = "/etc/nixos/nix-swarm/secrets/swarm.cookie";
    openFirewall = true;
    firewallInterfaces = [ "eth0" ];
  };
}
```

### `cluster/cluster.nix`

```nix
{ ... }:
{
  imports = [
    ./services/gitea.nix
  ];

  services.swarm = {
    peers = [
      "swarm@192.168.1.226"
      "swarm@192.168.1.121"
    ];

    nodes = {
      "swarm@192.168.1.226" = {
        labels = [ "gitea" "ingress" ];
        deployHost = "root@192.168.1.226";
      };

      "swarm@192.168.1.121" = {
        labels = [ "gitea" "ingress" ];
        deployHost = "root@192.168.1.121";
      };
    };

    services.gitea = {
      constraints = [ "gitea" ];
      preferredNodes = [ "swarm@192.168.1.226" ];
      settings = {
        domain = "gitea.home";
        httpPort = 3003;
      };
    };

    ingress.sites.gitea = {
      domain = "gitea.home";
      service = "gitea";
      ports = [ 3003 ];
      default = true;
    };
  };
}
```

### `cluster/services/gitea.nix`

```nix
{ lib, ... }:
{
  networking.firewall.allowedTCPPorts = [ 3003 ];

  services.gitea.enable = true;
  services.gitea.stateDir = "/var/lib/gitea";
  services.gitea.settings.server.HTTP_PORT = 3003;

  systemd.services.gitea.wantedBy = lib.mkForce [];
}
```

## Day-to-day workflow

1. Launch `swarm --target NODE`
2. Inspect cluster health from **Dashboard**, **Map**, **Machines**, and **Services**
3. Use `a`, `e`, and `d` to manage machine/service files
4. Use `y` to preview and `p` to apply config changes
5. Use `u` to roll updated code/config to running nodes

## Development

```bash
mix format
mix test
```

## License

MIT. See [LICENSE](LICENSE).
