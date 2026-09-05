{ config, lib, pkgs, ... }:

let
  cfg = config.services.nix-swarm;
  inherit (lib) all attrValues concatMapStringsSep elem filterAttrs genAttrs hasInfix last mapAttrs mapAttrs' mapAttrsToList mkEnableOption mkIf mkMerge mkOption splitString types;

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

  mkProxyRoute = name: routeCfg: {
    name = name;
    host = routeCfg.host;
    path_prefix = routeCfg.pathPrefix;
    upstreams = routeCfg.upstreams;
    auth = routeCfg.auth;
    oidc =
      if routeCfg.oidc == null then
        null
      else
        {
          redirect_base = routeCfg.oidc.redirectBase;
          scope = routeCfg.oidc.scope;
        };
  };

  proxyRenderedConfigText = ''
    {listen_port, ${toString cfg.proxy.listen.port}}.
    {session_ttl_sec, 3600}.
    {oidc, ${toErlTerm {
      issuer = cfg.proxy.oidc.issuer;
      client_id = cfg.proxy.oidc.clientId;
      scope = cfg.proxy.oidc.scope;
      redirect_base = null;
    }}}.
    {routes, ${toErlTerm (mapAttrsToList mkProxyRoute cfg.proxy.routes)}}.
  '';

  rawProxyRenderedConfig = pkgs.writeText "nix-swarm.proxy.config.unvalidated" proxyRenderedConfigText;

  renderedProxyConfig = pkgs.runCommand "nix-swarm.proxy.config" { } ''
    cp ${rawProxyRenderedConfig} "$out"
    ${pkgs.beamPackages.erlang}/bin/erl -noshell -eval 'case file:consult("'$out'") of {ok, _Terms} -> halt(0); {error, Reason} -> io:format(standard_error, "invalid nix-swarm proxy config: ~p~n", [Reason]), halt(1) end.'
  '';

  proxyStart = pkgs.writeShellScript "nix-swarm-proxy-start" ''
    exec ${cfg.package}/bin/nix-swarmd proxy
  '';

  mkNodeEntry = name: nodeCfg: ''
    {${toErlTerm name}, [
      {availability, ${toErlTerm nodeCfg.availability}},
      {deploy_host, ${toErlTerm nodeCfg.deployHost}},
      {nixos_configuration, ${toErlTerm nodeCfg.nixosConfiguration}}
    ]}
  '';

  mkServiceEntry = name: serviceCfg: ''
    [
      {name, ${toErlTerm name}},
      {replicas, ${toString serviceCfg.replicas}},
      {unit_template, ${toErlTerm (effectiveUnitTemplate name serviceCfg)}},
      {allowed_nodes, ${mkStringList serviceCfg.allowedNodes}},
      {autoscaling, ${toErlTerm (serviceCfg.autoscaling // {
        minReplicas = if serviceCfg.autoscaling.minReplicas == null then serviceCfg.replicas else serviceCfg.autoscaling.minReplicas;
        maxReplicas = if serviceCfg.autoscaling.maxReplicas == null then serviceCfg.replicas else serviceCfg.autoscaling.maxReplicas;
      })}},
      {state, ${toErlTerm serviceCfg.state}}
    ]
  '';

  effectiveRestore = serviceCfg:
    if serviceCfg.state == null then
      "none"
    else if serviceCfg.state.restore != null then
      serviceCfg.state.restore
    else if serviceCfg.state.backup != null then
      "borg-latest"
    else
      "none";

  statefulBackupServices = filterAttrs
    (_: serviceCfg: serviceCfg.state != null && serviceCfg.state.backup != null)
    cfg.services;

  borgmaticConfigs = mapAttrs (name: serviceCfg:
    let
      sourceLines = concatMapStringsSep "\n" (dir: "        - " + dir) serviceCfg.state.dirs;
      header = ''
        location:
          source_directories:
      '';
      body = ''
          repositories:
            - path: ${serviceCfg.state.backup.target}
        storage:
          encryption_passcommand: cat $CREDENTIALS_DIRECTORY/borg-passphrase
        retention:
          keep_hourly: 24
          keep_daily: 7
          keep_weekly: 4
      '';
    in
    pkgs.writeText "nix-swarm-borgmatic-${name}.yaml" (header + sourceLines + body)
  ) statefulBackupServices;

  backupServices = mapAttrs'
    (name: serviceCfg:
      lib.nameValuePair "nix-swarm-backup-${name}" {
        description = "Nix-Swarm borg backup of ${name} state";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          LoadCredential = [ "borg-passphrase:${cfg.backupCredentialDir}/${name}.borg-passphrase" ];
          ExecStart = "${pkgs.borgmatic}/bin/borgmatic --config ${borgmaticConfigs.${name}} --verbosity 1";
        };
      })
    statefulBackupServices;

  backupTimers = mapAttrs'
    (name: serviceCfg:
      lib.nameValuePair "nix-swarm-backup-${name}" {
        description = "Scheduled Nix-Swarm borg backup of ${name} state";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = serviceCfg.state.backup.schedule;
          Persistent = true;
        };
      })
    statefulBackupServices;

  # Operator-invoked restore wrapper: restores the latest archive from the
  # service's borg repository into a staging directory on this node. The
  # repository passphrase is read from the root-only credential file, never
  # embedded in the script or Nix.
  restoreWrappers = mapAttrs'
    (name: serviceCfg:
      lib.nameValuePair "nix-swarm-restore-${name}" (
        pkgs.writeShellScriptBin "nix-swarm-restore-${name}" ''
          set -eu
          if [ "$#" -lt 1 ]; then
            echo "usage: nix-swarm-restore-${name} STAGING_DIR" >&2
            exit 2
          fi
          credential_file=${cfg.backupCredentialDir}/${name}.borg-passphrase
          export BORG_PASSPHRASE=$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$credential_file")
          exec ${pkgs.borgmatic}/bin/borgmatic restore --config ${borgmaticConfigs.${name}} --archive latest --destination "$1"
        ''
      ))
    statefulBackupServices;

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
    in
    allowedOk;

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
            assertion = !serviceCfg.autoscaling.enable || (
              effectiveMinReplicas serviceCfg >= 0
                && effectiveMinReplicas serviceCfg <= serviceCfg.replicas
                && effectiveMaxReplicas serviceCfg >= serviceCfg.replicas
                && effectiveMaxReplicas serviceCfg <= 128
                && serviceCfg.autoscaling.cpuTargetPercent >= 1
                && serviceCfg.autoscaling.cpuTargetPercent <= 100
                && serviceCfg.autoscaling.memoryTargetPercent >= 1
                && serviceCfg.autoscaling.memoryTargetPercent <= 100
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
            assertion = serviceCfg.state == null || serviceCfg.replicas == 1;
            message = "services.nix-swarm.services.${name}.state requires replicas = 1 (single-writer state)";
          }
          {
            assertion = serviceCfg.state == null || !serviceCfg.autoscaling.enable || effectiveMaxReplicas serviceCfg <= 1;
            message = "services.nix-swarm.services.${name}.state must not autoscale beyond one replica";
          }
          {
            assertion = serviceCfg.state == null || serviceCfg.state.dirs != [ ];
            message = "services.nix-swarm.services.${name}.state.dirs must not be empty";
          }
          {
            assertion = serviceCfg.state == null || all (dir: builtins.hasPrefix "/" dir) serviceCfg.state.dirs;
            message = "services.nix-swarm.services.${name}.state.dirs must be absolute paths";
          }
          {
            assertion = serviceCfg.state == null || serviceCfg.state.backup != null || effectiveRestore serviceCfg == "none";
            message = "services.nix-swarm.services.${name}.state.restore requires a state.backup block";
          }

        ]
      )
      (builtins.attrNames cfg.services));

  proxyOidcRouteNames = builtins.attrNames (filterAttrs (_: routeCfg: routeCfg.auth == "oidc") cfg.proxy.routes);

  proxyAssertions = [
    {
      assertion = !cfg.proxy.enable || proxyOidcRouteNames == [ ] || cfg.proxy.oidc.clientId != "";
      message = "services.nix-swarm.proxy.oidc.clientId must not be empty when an OIDC route is configured";
    }
    {
      assertion = !cfg.proxy.enable || all (routeCfg: routeCfg.host != "") (attrValues cfg.proxy.routes);
      message = "services.nix-swarm.proxy route host must be non-empty";
    }
    {
      assertion = !cfg.proxy.enable || all (routeCfg: routeCfg.upstreams != [ ]) (attrValues cfg.proxy.routes);
      message = "services.nix-swarm.proxy route upstreams must not be empty";
    }
    {
      assertion = !cfg.proxy.enable || all (routeCfg: all (upstream: builtins.match "[A-Za-z0-9.-]+:[0-9]+" upstream != null) routeCfg.upstreams) (attrValues cfg.proxy.routes);
      message = "services.nix-swarm.proxy upstreams must match host:port without scheme or path";
    }
    {
      assertion = !cfg.proxy.enable || all (name: builtins.match "[A-Za-z0-9][A-Za-z0-9._@-]*" name != null && !(hasInfix ".." name)) (builtins.attrNames cfg.proxy.routes);
      message = "services.nix-swarm.proxy route names must contain only safe characters";
    }
    {
      assertion = !cfg.proxy.enable || !cfg.proxy.openFirewall || cfg.proxy.firewallInterfaces != [ ];
      message = "services.nix-swarm.proxy.openFirewall requires firewallInterfaces so the proxy is never exposed on every interface";
    }
    {
      assertion = cfg.proxy.clientSecretFile == null || (lib.hasPrefix "/" cfg.proxy.clientSecretFile && !lib.hasPrefix "/nix/store/" cfg.proxy.clientSecretFile);
      message = "services.nix-swarm.proxy.clientSecretFile must be an absolute, out-of-store secret path";
    }
    {
      assertion = cfg.proxy.sessionSecretFile == null || (lib.hasPrefix "/" cfg.proxy.sessionSecretFile && !lib.hasPrefix "/nix/store/" cfg.proxy.sessionSecretFile);
      message = "services.nix-swarm.proxy.sessionSecretFile must be an absolute, out-of-store secret path";
    }
    {
      assertion = !cfg.proxy.enable || proxyOidcRouteNames == [ ] || cfg.proxy.clientSecretFile != null;
      message = "services.nix-swarm.proxy.clientSecretFile is required when an OIDC route is configured";
    }
    {
      assertion = !cfg.proxy.enable || proxyOidcRouteNames == [ ] || cfg.proxy.sessionSecretFile != null;
      message = "services.nix-swarm.proxy.sessionSecretFile is required when an OIDC route is configured";
    }
    {
      assertion = !cfg.proxy.enable || all (name: cfg.proxy.routes.${name}.auth != "oidc" || (cfg.proxy.routes.${name}.oidc != null && cfg.proxy.routes.${name}.oidc.redirectBase != null)) (builtins.attrNames cfg.proxy.routes);
      message = "services.nix-swarm.proxy OIDC routes require oidc.redirectBase";
    }
  ];

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
      {executor, [{adapter, systemd}]}
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

  ];
in
{
  imports = [ ./hardened.nix ];

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

    runtime = mkOption {
      type = types.submodule {
        options = {
          connectIntervalMs = mkOption {
            type = types.ints.between 500 3600000;
            default = 1000;
            description = "Peer reconnect probe interval in milliseconds.";
          };

          reconcileIntervalMs = mkOption {
            type = types.ints.between 500 3600000;
            default = 1000;
            description = "Reconciliation tick interval in milliseconds.";
          };

          autoscaleIntervalMs = mkOption {
            type = types.ints.between 500 3600000;
            default = 1000;
            description = "Autoscaler evaluation interval in milliseconds.";
          };

          failureGraceMs = mkOption {
            type = types.ints.between 1000 3600000;
            default = 5000;
            description = "Grace period before a suspected peer is marked down, in milliseconds.";
          };

          recoveryStabilizationMs = mkOption {
            type = types.ints.between 500 3600000;
            default = 2000;
            description = "Stabilization window before a recovering peer is marked up, in milliseconds.";
          };

          commandTimeoutMs = mkOption {
            type = types.ints.between 1000 300000;
            default = 5000;
            description = "Bounded timeout for remote executor commands, in milliseconds.";
          };
        };
      };
      default = { };
      description = "Operational timing policy for cluster discovery, reconciliation, and remote commands.";
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

    backupCredentialDir = mkOption {
      type = types.str;
      default = "/etc/nixos/nix-swarm/secrets";
      description = "Directory holding root-only `<service>.borg-passphrase` files loaded by generated backup units through LoadCredential.";
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


          unitTemplate = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional systemd unit template rendered by Nix-Swarm. Defaults to `%{service}.service` for one replica and `%{service}@%{slot}.service` for multiple replicas.";
          };


          allowedNodes = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Optional hard allowlist of peer node names. Empty means no hard node restriction.";
          };


          autoscaling = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = "Enable opinionated CPU-and-memory autoscaling. This explicitly asserts that concurrent instances are safe.";
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
            memoryTargetPercent = mkOption { type = types.int; default = 80; };
          };

          state = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                dirs = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Declared absolute state directories owned by the service on its host node. The reconciler refuses to start the unit while any is absent (awaiting_heal) when a restore strategy is declared.";
                };

                backup = mkOption {
                  type = types.nullOr (types.submodule {
                    options = {
                      schedule = mkOption {
                        type = types.str;
                        default = "hourly";
                        description = "systemd OnCalendar schedule for the generated borgmatic timer.";
                      };
                      target = mkOption {
                        type = types.str;
                        description = "Opaque borg repository URI (local path, ssh:, or S3-compatible endpoint such as Garage). Credentials go through LoadCredential, never in the URI or Nix.";
                      };
                    };
                  });
                  default = null;
                  description = "Declared borg backup schedule and repository for this service's state directories.";
                };

                restore = mkOption {
                  type = types.nullOr (types.enum [ "borg-latest" "litestream" "none" ]);
                  default = null;
                  description = "Restore strategy before start; defaults to \"borg-latest\" when a backup block exists, otherwise \"none\".";
                };

                autoHeal = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Whether the cluster may heal this service onto a surviving node automatically after its owner has been down beyond healGraceSec.";
                };

                healGraceSec = mkOption {
                  type = types.ints.between 1 31536000;
                  default = 600;
                  description = "Minimum owner downtime before an automatic heal is considered.";
                };
              };
            });
            default = null;
            description = "Optional single-writer state contract: directories, backup schedule/target, restore strategy, and auto-heal policy. Requires replicas = 1.";
          };

        };
      }));
      default = { };
      description = "Cluster services keyed by logical service name.";
    };

    proxy = mkOption {
      type = types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Enable the optional built-in BEAM edge proxy.";
          };

          listen.port = mkOption {
            type = types.port;
            default = 8080;
            description = "TCP port on which the built-in proxy listens.";
          };

          openFirewall = mkOption {
            type = types.bool;
            default = false;
            description = "Open the proxy listen port on explicitly named firewall interfaces.";
          };

          firewallInterfaces = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Interfaces on which to allow proxy traffic when openFirewall is enabled.";
          };

          routes = mkOption {
            type = types.attrsOf (types.submodule {
              options = {
                host = mkOption { type = types.str; default = ""; };
                pathPrefix = mkOption { type = types.str; default = "/"; };
                upstreams = mkOption { type = types.listOf types.str; default = [ ]; };
                auth = mkOption { type = types.enum [ "public" "oidc" ]; default = "public"; };
                oidc = mkOption {
                  type = types.nullOr (types.submodule {
                    options = {
                      redirectBase = mkOption { type = types.nullOr types.str; default = null; };
                      scope = mkOption { type = types.nullOr types.str; default = null; };
                    };
                  });
                  default = null;
                };
              };
            });
            default = { };
            description = "Static host/path routes and their upstreams.";
          };

          oidc = mkOption {
            type = types.submodule {
              options = {
                issuer = mkOption { type = types.str; default = ""; };
                clientId = mkOption { type = types.str; default = ""; };
                scope = mkOption { type = types.str; default = "openid email profile"; };
              };
            };
            default = { };
            description = "Public OIDC provider configuration; credentials are supplied separately.";
          };

          clientSecretFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Out-of-store file loaded as the OIDC client secret.";
          };

          sessionSecretFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Out-of-store file loaded as the encrypted session secret.";
          };
        };
      };
      default = { };
      description = "Optional built-in BEAM edge proxy configuration, disabled by default.";
    };


  };

  config = mkIf cfg.enable {
    assertions = topologyAssertions ++ serviceAssertions ++ proxyAssertions;

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


    networking.firewall = mkMerge [
      (mkIf (cfg.openFirewall && cfg.firewallInterfaces == [ ]) {
        allowedTCPPorts = [ cfg.epmdPort cfg.distributionPort ];
      })
      (mkIf (cfg.openFirewall && cfg.firewallInterfaces != [ ]) {
        interfaces = genAttrs cfg.firewallInterfaces (_: {
          allowedTCPPorts = [ cfg.epmdPort cfg.distributionPort ];
        });
      })
      (mkIf (cfg.proxy.enable && cfg.proxy.openFirewall) {
        interfaces = genAttrs cfg.proxy.firewallInterfaces (_: {
          allowedTCPPorts = [ cfg.proxy.listen.port ];
        });
      })
    ];

    environment.systemPackages = [ cfg.package ] ++ (attrValues restoreWrappers);

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

    systemd.services = mkMerge [
      (mkIf cfg.enableDaemon {
        nix-swarmd = {
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
          ''"ERL_AFLAGS=-kernel net_ticktime 10 inet_dist_listen_min ${toString cfg.distributionPort} inet_dist_listen_max ${toString cfg.distributionPort}"''
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
        MemoryMax = "512M";
        TasksMax = 512;
        LimitNOFILE = 8192;
        SystemCallArchitectures = "native";
      };
      startLimitIntervalSec = 120;
      startLimitBurst = 10;
      restartTriggers = [ renderedConfig cfg.package ];
        };
      })
      backupServices
      (mkIf cfg.proxy.enable {
        nix-swarm-proxy = {
          description = "Nix-Swarm optional built-in edge proxy";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            User = "nix-swarm";
            Group = cfg.operatorGroup;
            Type = "simple";
            Restart = "on-failure";
            Environment = [
              "NIX_SWARM_ROLE=proxy"
              "NIX_SWARM_PROXY_CONFIG_PATH=${renderedProxyConfig}"
              "HOME=/run/nix-swarm-proxy"
            ];
            LoadCredential =
              (lib.optional (cfg.proxy.clientSecretFile != null) "proxy-client-secret:${cfg.proxy.clientSecretFile}")
              ++ (lib.optional (cfg.proxy.sessionSecretFile != null) "proxy-session-secret:${cfg.proxy.sessionSecretFile}");
            ExecStart = proxyStart;
            RuntimeDirectory = "nix-swarm-proxy";
            RuntimeDirectoryMode = "0700";
            UMask = "0077";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
          };
          restartTriggers = [ renderedProxyConfig cfg.package ];
        };
      })
    ];

    systemd.timers = backupTimers;

  };
}
