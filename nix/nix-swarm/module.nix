{ config, lib, pkgs, ... }:

let
  cfg = config.services.nix-swarm;
  inherit (lib) all concatMapStringsSep elem genAttrs hasInfix last mapAttrsToList mkEnableOption mkIf mkMerge mkOption optional splitString types;

  escapeErlString = value:
    builtins.replaceStrings
      [ "\\" "\"" "\n" "\r" "\t" ]
      [ "\\\\" "\\\"" "\\n" "\\r" "\\t" ]
      value;

  escapeErlAtom = value:
    builtins.replaceStrings
      [ "\\" "'" "\n" "\r" "\t" ]
      [ "\\\\" "\\'" "\\n" "\\r" "\\t" ]
      value;

  toErlAtom = value: "'${escapeErlAtom value}'";

  toErlTerm =
    value:
    if value == null then
      "undefined"
    else if builtins.isBool value then
      if value then "true" else "false"
    else if builtins.isInt value then
      toString value
    else if builtins.isString value then
      "<<\"${escapeErlString value}\">>"
    else if builtins.isList value then
      "[${concatMapStringsSep ", " toErlTerm value}]"
    else if builtins.isAttrs value then
      "[${concatMapStringsSep ", " (name: "{${toErlAtom name}, ${toErlTerm value.${name}}}") (builtins.attrNames value)}]"
    else
      throw "unsupported Erlang term conversion in nix-swarm-module.nix";

  mkStringList = values:
    "[${concatMapStringsSep ", " toErlTerm values}]";

  mkNodeEntry = name: nodeCfg: ''
    {${toErlTerm name}, [
      {labels, ${mkStringList nodeCfg.labels}},
      {availability, ${toErlTerm nodeCfg.availability}},
      {deploy_host, ${toErlTerm nodeCfg.deployHost}},
      {nixos_configuration, ${toErlTerm nodeCfg.nixosConfiguration}}
    ]}
  '';

  mkServiceEntry = name: serviceCfg: ''
    [
      {name, ${toErlTerm name}},
      {replicas, ${toString serviceCfg.replicas}},
      {max_replicas_per_node, ${toErlTerm serviceCfg.maxReplicasPerNode}},
      {unit_template, ${toErlTerm (effectiveUnitTemplate name serviceCfg)}},
      {constraints, ${mkStringList serviceCfg.constraints}},
      {allowed_nodes, ${mkStringList serviceCfg.allowedNodes}},
      {preferred_nodes, ${mkStringList serviceCfg.preferredNodes}},
      {readiness, ${toErlTerm serviceCfg.readiness}},
      {autoscaling, ${toErlTerm (serviceCfg.autoscaling // {
        minReplicas = if serviceCfg.autoscaling.minReplicas == null then serviceCfg.replicas else serviceCfg.autoscaling.minReplicas;
        maxReplicas = if serviceCfg.autoscaling.maxReplicas == null then serviceCfg.replicas else serviceCfg.autoscaling.maxReplicas;
      })}},
      {healthcheck, ${toErlTerm serviceCfg.healthcheck}},
      {settings, ${toErlTerm serviceCfg.settings}}
    ]
  '';

  mkIngressEntry = name: siteCfg: ''
    [
      {name, ${toErlTerm name}},
      {domain, ${toErlTerm siteCfg.domain}},
      {service, ${toErlTerm siteCfg.service}},
      {ports, ${mkStringList siteCfg.ports}},
      {base_port, ${toErlTerm siteCfg.basePort}},
      {scheme, ${toErlTerm siteCfg.scheme}},
      {default, ${toErlTerm siteCfg.default}}
    ]
  '';

  effectiveUnitTemplate = name: serviceCfg:
    if serviceCfg.unitTemplate != null then
      serviceCfg.unitTemplate
    else if effectiveMaxReplicas serviceCfg <= 1 then
      "%{service}.service"
    else
      "%{service}@%{slot}.service";

  effectiveMinReplicas = serviceCfg:
    if serviceCfg.autoscaling.minReplicas == null then serviceCfg.replicas else serviceCfg.autoscaling.minReplicas;

  effectiveMaxReplicas = serviceCfg:
    if !serviceCfg.autoscaling.enable then
      serviceCfg.replicas
    else if serviceCfg.autoscaling.maxReplicas == null then
      serviceCfg.replicas
    else
      serviceCfg.autoscaling.maxReplicas;

  nodeEligibleFor = serviceCfg: node:
    let
      nodeCfg = cfg.nodes.${node};
      allowedOk = serviceCfg.allowedNodes == [ ] || elem node serviceCfg.allowedNodes;
      labelsOk = all (label: elem label nodeCfg.labels) serviceCfg.constraints;
    in
    allowedOk && labelsOk;

  preferredNodesEligible = serviceCfg:
    all (node: elem node cfg.peers && builtins.hasAttr node cfg.nodes && nodeEligibleFor serviceCfg node) serviceCfg.preferredNodes;

  allowedNodesKnown = serviceCfg:
    all (node: elem node cfg.peers) serviceCfg.allowedNodes;

  managedUnits =
    builtins.concatLists
      (mapAttrsToList
        (name: serviceCfg:
          # Keep the validated slot namespace authorized across replica reductions and zero-replica transitions.
          builtins.genList
            (index:
              builtins.replaceStrings
                [ "%{service}" "%{slot}" ]
                [ name (toString index) ]
                (effectiveUnitTemplate name serviceCfg)
            )
            128
        )
        cfg.services) ++ cfg.extraManagedUnits;

  serviceAssertions =
    builtins.concatLists (map
      (name:
        let
          serviceCfg = cfg.services.${name};
          template = effectiveUnitTemplate name serviceCfg;
        in
        [
          {
            assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9._@-]*" name != null && !(hasInfix ".." name);
            message = "services.nix-swarm.services.${name} has an unsafe service name";
          }
          {
            assertion = serviceCfg.replicas >= 0 && serviceCfg.replicas <= 128;
            message = "services.nix-swarm.services.${name}.replicas must be between 0 and 128";
          }
          {
            assertion = effectiveMaxReplicas serviceCfg <= 1 || hasInfix "%{slot}" template;
            message = "services.nix-swarm.services.${name}.unitTemplate must include `%{slot}` when replica capacity is greater than 1";
          }
          {
            assertion = serviceCfg.maxReplicasPerNode == null || (serviceCfg.maxReplicasPerNode >= 1 && serviceCfg.maxReplicasPerNode <= 128);
            message = "services.nix-swarm.services.${name}.maxReplicasPerNode must be between 1 and 128";
          }
          {
            assertion = serviceCfg.readiness.timeoutSec >= 1 && serviceCfg.readiness.timeoutSec <= 3600
              && serviceCfg.readiness.stableSamples >= 1 && serviceCfg.readiness.stableSamples <= 60;
            message = "services.nix-swarm.services.${name}.readiness values are outside their supported ranges";
          }
          {
            assertion = !serviceCfg.autoscaling.enable || (
              effectiveMinReplicas serviceCfg >= 0
                && effectiveMinReplicas serviceCfg <= serviceCfg.replicas
                && effectiveMaxReplicas serviceCfg >= serviceCfg.replicas
                && effectiveMaxReplicas serviceCfg <= 128
                && serviceCfg.autoscaling.cpuTargetPercent >= 1
                && serviceCfg.autoscaling.cpuTargetPercent <= 100
                && serviceCfg.autoscaling.sampleWindowSec >= 1
                && serviceCfg.autoscaling.sampleWindowSec <= 3600
                && serviceCfg.autoscaling.scaleUpCooldownSec >= 0
                && serviceCfg.autoscaling.scaleUpCooldownSec <= 86400
                && serviceCfg.autoscaling.scaleDownCooldownSec >= 0
                && serviceCfg.autoscaling.scaleDownCooldownSec <= 86400
                && serviceCfg.autoscaling.maxStep >= 1
                && serviceCfg.autoscaling.maxStep <= 128
            );
            message = "services.nix-swarm.services.${name}.autoscaling values are inconsistent or outside supported ranges";
          }
          {
            assertion = builtins.match "[A-Za-z0-9_][A-Za-z0-9._@:%{}-]*" template != null && !(hasInfix ".." template);
            message = "services.nix-swarm.services.${name}.unitTemplate must render a safe systemd unit name";
          }
          {
            assertion = allowedNodesKnown serviceCfg;
            message = "services.nix-swarm.services.${name}.allowedNodes must reference configured peers";
          }
          {
            assertion = preferredNodesEligible serviceCfg;
            message = "services.nix-swarm.services.${name}.preferredNodes must reference nodes eligible after allowedNodes and constraints";
          }
        ]
      )
      (builtins.attrNames cfg.services));

  renderedConfigText = ''
    {peers, ${mkStringList cfg.peers}}.
    {nodes, [
      ${concatMapStringsSep ",\n      " (entry: entry) (mapAttrsToList mkNodeEntry cfg.nodes)}
    ]}.
    {services, [
      ${concatMapStringsSep ",\n      " (entry: entry) (mapAttrsToList mkServiceEntry cfg.services)}
    ]}.
    {runtime, [
      {connect_interval_ms, ${toString cfg.runtime.connectIntervalMs}},
      {reconcile_interval_ms, ${toString cfg.runtime.reconcileIntervalMs}},
      {autoscale_interval_ms, ${toString cfg.runtime.autoscaleIntervalMs}},
      {failure_grace_ms, ${toString cfg.runtime.failureGraceMs}},
      {recovery_stabilization_ms, ${toString cfg.runtime.recoveryStabilizationMs}},
      {command_timeout_ms, ${toString cfg.runtime.commandTimeoutMs}},
      {generation, ${toErlTerm cfg.runtime.generation}},
      {executor, [{adapter, systemd}]}
    ]}.
    {ingress, [
      ${concatMapStringsSep ",\n      " (entry: entry) (mapAttrsToList mkIngressEntry cfg.ingress.sites)}
    ]}.
  '';

  rawRenderedConfig = pkgs.writeText "nix-swarm.config.unvalidated" renderedConfigText;

  renderedConfig = pkgs.runCommand "nix-swarm.config" { } ''
    cp ${rawRenderedConfig} "$out"
    ${pkgs.beamPackages.erlang}/bin/erl -noshell -eval 'case file:consult("'$out'") of {ok, _Terms} -> halt(0); {error, Reason} -> io:format(standard_error, "invalid nix-swarm config: ~p~n", [Reason]), halt(1) end.'
  '';

  nodeHost = last (splitString "@" cfg.nodeName);

  releaseDistribution =
    if hasInfix "." nodeHost then
      "name"
    else
      "sname";

  swarmdStart = pkgs.writeShellScript "nix-swarmd-start" ''
    cookie_file="$CREDENTIALS_DIRECTORY/nix-swarm-cookie"
    cookie="$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$cookie_file")"

    if [ "''${#cookie}" -lt 32 ] || [ "''${#cookie}" -gt 64 ] || \
       ! ${pkgs.gnugrep}/bin/grep -Eq '^[A-Za-z0-9_.+/=-]+$' <<< "$cookie"; then
      echo "nix-swarmd: cookie must contain 32-64 safe characters" >&2
      exit 1
    fi

    beam_home="$RUNTIME_DIRECTORY/beam"
    ${pkgs.coreutils}/bin/install -d -m 0700 "$beam_home"
    ${pkgs.coreutils}/bin/install -m 0400 "$cookie_file" "$beam_home/.erlang.cookie"
    export HOME="$beam_home"
    unset NIX_SWARM_COOKIE NIX_SWARM_COOKIE_FILE RELEASE_COOKIE
    exec ${cfg.package}/bin/nix-swarmd start
  '';

  topologyAssertions = [
    {
      assertion = elem cfg.nodeName cfg.peers;
      message = "services.nix-swarm.nodeName must be present in services.nix-swarm.peers";
    }
    {
      assertion = all (node: builtins.hasAttr node cfg.nodes) cfg.peers;
      message = "every services.nix-swarm.peers entry must have matching nodes metadata";
    }
    {
      assertion = all (node: cfg.nodes.${node}.deployHost != "") (builtins.attrNames cfg.nodes);
      message = "every services.nix-swarm.nodes entry must define a non-empty deployHost";
    }
    {
      assertion = cfg.epmdPort != cfg.distributionPort;
      message = "services.nix-swarm.epmdPort and distributionPort must be different";
    }
    {
      assertion =
        cfg.runtime.connectIntervalMs >= 100 && cfg.runtime.connectIntervalMs <= 3600000
        && cfg.runtime.reconcileIntervalMs >= 100 && cfg.runtime.reconcileIntervalMs <= 3600000
        && cfg.runtime.autoscaleIntervalMs >= 100 && cfg.runtime.autoscaleIntervalMs <= 3600000
        && cfg.runtime.failureGraceMs >= 100 && cfg.runtime.failureGraceMs <= 3600000
        && cfg.runtime.recoveryStabilizationMs >= 100 && cfg.runtime.recoveryStabilizationMs <= 3600000
        && cfg.runtime.commandTimeoutMs >= 100 && cfg.runtime.commandTimeoutMs <= 300000;
      message = "services.nix-swarm.runtime intervals must be 100-3600000ms and commandTimeoutMs must be 100-300000ms";
    }
    {
      assertion = lib.hasPrefix "/" cfg.cookieFile && !lib.hasPrefix "/nix/store/" cfg.cookieFile;
      message = "services.nix-swarm.cookieFile must be an absolute, out-of-store secret path";
    }
    {
      assertion = !cfg.openFirewall || cfg.firewallInterfaces != [ ];
      message = "services.nix-swarm.openFirewall requires firewallInterfaces so BEAM distribution is never exposed on every interface";
    }
    {
      assertion = all (unit: builtins.match "[A-Za-z0-9_][A-Za-z0-9._@:-]*" unit != null && !(hasInfix ".." unit)) cfg.extraManagedUnits;
      message = "services.nix-swarm.extraManagedUnits must contain only exact, safe systemd unit names";
    }
    {
      assertion = !elem "nix-swarm" cfg.operatorUsers;
      message = "services.nix-swarm.operatorUsers must not contain the managed nix-swarm system user";
    }
    {
      assertion = cfg.resourceLimits.tasksMax >= 16 && cfg.resourceLimits.tasksMax <= 4096;
      message = "services.nix-swarm.resourceLimits.tasksMax must be between 16 and 4096";
    }
    {
      assertion = cfg.deployment.healthTimeoutSec >= 1 && cfg.deployment.healthTimeoutSec <= 3600;
      message = "services.nix-swarm.deployment.healthTimeoutSec must be between 1 and 3600";
    }
    {
      assertion = cfg.deployment.stableSamples >= 1 && cfg.deployment.stableSamples <= 60;
      message = "services.nix-swarm.deployment.stableSamples must be between 1 and 60";
    }
    {
      assertion = cfg.deployment.stableSamples <= cfg.deployment.healthTimeoutSec;
      message = "services.nix-swarm.deployment.stableSamples must not exceed healthTimeoutSec";
    }
    {
      assertion = all (service: service.readiness.timeoutSec <= cfg.deployment.healthTimeoutSec) (builtins.attrValues cfg.services);
      message = "service readiness.timeoutSec values must not exceed deployment.healthTimeoutSec";
    }
  ];
in
{
  imports = [ ./hardened.nix ./ingress.nix ];

  options.services.nix-swarm = {
    enable = mkEnableOption "the Nix-Swarm leaderless cluster runtime";

    hardened = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the minimal hardened NixOS host baseline for this node. Deployment keys, overlay networking, and the cookie remain machine-specific.";
    };

    package = mkOption {
      type = types.package;
      default = import ./package.nix { inherit pkgs; };
      description = "Package containing the Nix-Swarm node runtime (`bin/nix-swarmd`). Defaults to the dedicated cluster package.";
    };

    nodeName = mkOption {
      type = types.str;
      description = "Distributed Erlang node name for this machine.";
    };

    cookieFile = mkOption {
      type = types.str;
      description = "Absolute path on the target machine to the Erlang cookie file used by all Nix-Swarm peers.";
    };

    operatorGroup = mkOption {
      type = types.str;
      default = "nix-swarm-operators";
      description = "Local group allowed to use the read-only query socket over SSH.";
    };

    operatorUsers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Existing local users added to the read-only Nix-Swarm operator group.";
    };

    extraManagedUnits = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional exact systemd unit names the unprivileged agent may manage during migrations.";
    };

    epmdPort = mkOption {
      type = types.port;
      default = 4369;
      description = "TCP port used by epmd for Erlang node discovery.";
    };

    distributionPort = mkOption {
      type = types.port;
      default = 4370;
      description = "Fixed TCP port used by distributed Erlang between trusted Nix-Swarm agents.";
    };

    enableDaemon = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the nix-swarmd node runtime daemon.";
    };

    onFailureUnits = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Existing systemd units triggered when nix-swarmd fails, for example a native notification service.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to open the epmd and distributed Erlang TCP ports in the NixOS firewall.";
    };

    firewallInterfaces = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Private or overlay-network interfaces on which to allow BEAM peer traffic.";
    };

    peers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "All peer node names in the cluster.";
    };

    nodes = mkOption {
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          labels = mkOption {
            type = types.listOf types.str;
            default = [ ];
          };

          availability = mkOption {
            type = types.enum [ "active" "draining" "maintenance" ];
            default = "active";
            description = "Declarative placement state. Draining and maintenance nodes receive no assignments; maintenance nodes are excluded from deploy membership gates.";
          };

          deployHost = mkOption {
            type = types.str;
            description = "SSH host used by `nix-swarm update` when this node is live.";
          };

          nixosConfiguration = mkOption {
            type = types.str;
            default = builtins.head (splitString "." (last (splitString "@" name)));
            description = "Attribute name under flake.nixosConfigurations used for native deployment.";
          };
        };
      }));
      default = { };
      description = "Node metadata keyed by node name.";
    };

    services = mkOption {
      type = types.attrsOf (types.submodule ({ ... }: {
        options = {
          replicas = mkOption {
            type = types.int;
            default = 1;
          };

          maxReplicasPerNode = mkOption {
            type = types.nullOr types.int;
            default = null;
            description = "Optional cap on replicas of this service assigned to one node.";
          };

          unitTemplate = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional systemd unit template rendered by Nix-Swarm. Defaults to `%{service}.service` for one replica and `%{service}@%{slot}.service` for multiple replicas.";
          };

          constraints = mkOption {
            type = types.listOf types.str;
            default = [ ];
          };

          allowedNodes = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Optional hard allowlist of peer node names. Empty means no hard node restriction.";
          };

          preferredNodes = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Preferred nodes for this service, listed in highest-to-lowest preference order.";
          };

          readiness = {
            timeoutSec = mkOption {
              type = types.int;
              default = 120;
              description = "Maximum time deployment health gates wait for systemd readiness.";
            };

            stableSamples = mkOption {
              type = types.int;
              default = 2;
              description = "Consecutive running samples required by deployment health gates.";
            };
          };

          autoscaling = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = "Enable leaderless, CPU-based autoscaling for this stateless service.";
            };

            minReplicas = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "Minimum autoscaled replicas; defaults to replicas.";
            };

            maxReplicas = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "Maximum autoscaled replicas and generated systemd unit capacity; defaults to replicas.";
            };

            cpuTargetPercent = mkOption { type = types.int; default = 65; };
            sampleWindowSec = mkOption { type = types.int; default = 60; };
            scaleUpCooldownSec = mkOption { type = types.int; default = 30; };
            scaleDownCooldownSec = mkOption { type = types.int; default = 300; };
            maxStep = mkOption { type = types.int; default = 1; };
          };

          healthcheck = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Deprecated display-only compatibility value. Nix-Swarm never executes this string.";
          };

          settings = mkOption {
            type = types.attrsOf (types.oneOf [ types.str types.int types.bool ]);
            default = { };
            description = "Public service metadata rendered through the Nix store. Never place secrets here.";
          };
        };
      }));
      default = { };
      description = "Cluster services keyed by logical service name.";
    };

    resourceLimits = {
      memoryMax = mkOption {
        type = types.str;
        default = "512M";
        description = "systemd MemoryMax for nix-swarmd.";
      };

      tasksMax = mkOption {
        type = types.int;
        default = 512;
        description = "systemd TasksMax for nix-swarmd.";
      };
    };

    deployment = {
      healthTimeoutSec = mkOption {
        type = types.int;
        default = 120;
        description = "Maximum time each rollout batch may take to become healthy.";
      };

      stableSamples = mkOption {
        type = types.int;
        default = 2;
        description = "Consecutive healthy cluster snapshots required before continuing a rollout.";
      };

      autoRollback = mkOption {
        type = types.bool;
        default = true;
        description = "Automatically roll back every host attempted by a failed deployment.";
      };
    };

    runtime = {
      connectIntervalMs = mkOption {
        type = types.int;
        default = 500;
      };

      reconcileIntervalMs = mkOption {
        type = types.int;
        default = 5000;
      };

      autoscaleIntervalMs = mkOption {
        type = types.int;
        default = 10000;
      };

      failureGraceMs = mkOption {
        type = types.int;
        default = 10000;
        description = "Time a disconnected peer remains suspect before its assignments are rebalanced.";
      };

      recoveryStabilizationMs = mkOption {
        type = types.int;
        default = 30000;
        description = "Time a returning peer remains unassigned before it is admitted back into placement.";
      };

      commandTimeoutMs = mkOption {
        type = types.int;
        default = 5000;
        description = "Timeout in milliseconds for local systemd/journal/metrics commands issued by the executor.";
      };

      generation = mkOption {
        type = types.str;
        default = "nixos";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = topologyAssertions ++ serviceAssertions;

    users.groups.${cfg.operatorGroup} = { };
    users.users = genAttrs cfg.operatorUsers (_: { extraGroups = [ cfg.operatorGroup ]; }) // {
      nix-swarm = {
        isSystemUser = true;
        group = cfg.operatorGroup;
        extraGroups = [ "systemd-journal" ];
      };
    };

    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        const managedUnits = ${builtins.toJSON managedUnits};
        const allowedVerbs = ["start", "stop", "restart", "reset-failed"];

        if (subject.user === "nix-swarm" &&
            action.id === "org.freedesktop.systemd1.manage-units" &&
            managedUnits.indexOf(action.lookup("unit")) !== -1 &&
            allowedVerbs.indexOf(action.lookup("verb")) !== -1) {
          return polkit.Result.YES;
        }
      });
    '';

    warnings = optional
      (builtins.any (service: service.healthcheck != null) (builtins.attrValues cfg.services))
      "services.nix-swarm.services.*.healthcheck shell commands are no longer executed; health is derived from systemd unit state";

    networking.firewall = mkMerge [
      (mkIf (cfg.openFirewall && cfg.firewallInterfaces == [ ]) {
        allowedTCPPorts = [ cfg.epmdPort cfg.distributionPort ];
      })
      (mkIf (cfg.openFirewall && cfg.firewallInterfaces != [ ]) {
        interfaces = genAttrs cfg.firewallInterfaces (_: {
          allowedTCPPorts = [ cfg.epmdPort cfg.distributionPort ];
        });
      })
    ];

    environment.systemPackages = [ cfg.package ];

    system.activationScripts.nixSwarmCookiePermissions.text = ''
      cookie_path=${lib.escapeShellArg cfg.cookieFile}

      if [ -e "$cookie_path" ]; then
        owner="$(${pkgs.coreutils}/bin/stat -c %U "$cookie_path")"
        mode="$(${pkgs.coreutils}/bin/stat -c %a "$cookie_path")"

        if [ "$owner" != root ] || { [ "$mode" != 400 ] && [ "$mode" != 600 ]; }; then
          echo "nix-swarm cookie must be root-owned with mode 0400 or 0600: $cookie_path" >&2
          exit 1
        fi
      fi
    '';

    systemd.services.nix-swarmd = mkIf cfg.enableDaemon {
      description = "Nix-Swarm leaderless node runtime";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      onFailure = cfg.onFailureUnits;

      serviceConfig = {
        User = "nix-swarm";
        Group = cfg.operatorGroup;
        Type = "notify";
        NotifyAccess = "all";
        WatchdogSec = "30s";
        TimeoutStartSec = "90s";
        TimeoutStopSec = "45s";
        KillMode = "mixed";
        Environment = [
          "NIX_SWARM_CONFIG_PATH=${renderedConfig}"
          "NIX_SWARM_ROLE=agent"
          "NIX_SWARM_STATE_DIR=/var/lib/nix-swarm"
          "NIX_SWARM_QUERY_SOCKET=/run/nix-swarm/query.sock"
          "NIX_SWARM_SYSTEMD_NOTIFY=${pkgs.systemd}/bin/systemd-notify"
          "RELEASE_NODE=${cfg.nodeName}"
          "RELEASE_DISTRIBUTION=${releaseDistribution}"
          "ERL_EPMD_PORT=${toString cfg.epmdPort}"
          ''"ERL_AFLAGS=-kernel inet_dist_listen_min ${toString cfg.distributionPort} inet_dist_listen_max ${toString cfg.distributionPort}"''
          "NIX_SWARM_DISTRIBUTION_PORT=${toString cfg.distributionPort}"
        ];
        LoadCredential = [ "nix-swarm-cookie:${cfg.cookieFile}" ];
        ExecStart = swarmdStart;
        Restart = "on-failure";
        RestartSec = 2;
        RestartSteps = 5;
        RestartMaxDelaySec = 30;
        StateDirectory = "nix-swarm";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "nix-swarm";
        RuntimeDirectoryMode = "0750";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        CapabilityBoundingSet = "";
        MemoryMax = cfg.resourceLimits.memoryMax;
        TasksMax = cfg.resourceLimits.tasksMax;
        LimitNOFILE = 8192;
        SystemCallArchitectures = "native";
      };
      startLimitIntervalSec = 120;
      startLimitBurst = 10;
      restartTriggers = [ renderedConfig cfg.package ];
    };

  };
}
