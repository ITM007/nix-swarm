{ config, lib, pkgs, ... }:

let
  cfg = config.services.nix-swarm;
  inherit (lib) all concatMapStringsSep elem genAttrs hasInfix last mapAttrsToList mkEnableOption mkIf mkMerge mkOption splitString types;

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
      {deploy_host, ${toErlTerm nodeCfg.deployHost}}
    ]}
  '';

  mkServiceEntry = name: serviceCfg: ''
      [
        {name, ${toErlTerm name}},
        {replicas, ${toString serviceCfg.replicas}},
        {unit_template, ${toErlTerm serviceCfg.unitTemplate}},
        {constraints, ${mkStringList serviceCfg.constraints}},
        {allowed_nodes, ${mkStringList serviceCfg.allowedNodes}},
        {preferred_nodes, ${mkStringList serviceCfg.preferredNodes}},
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
    else if serviceCfg.replicas <= 1 then
      "%{service}.service"
    else
      "%{service}@%{slot}.service";

  nodeEligibleFor = serviceCfg: node:
    let
      nodeCfg = cfg.nodes.${node};
      allowedOk = serviceCfg.allowedNodes == [] || elem node serviceCfg.allowedNodes;
      labelsOk = all (label: elem label nodeCfg.labels) serviceCfg.constraints;
    in
      allowedOk && labelsOk;

  preferredNodesEligible = serviceCfg:
    all (node: elem node cfg.peers && builtins.hasAttr node cfg.nodes && nodeEligibleFor serviceCfg node) serviceCfg.preferredNodes;

  allowedNodesKnown = serviceCfg:
    all (node: elem node cfg.peers) serviceCfg.allowedNodes;

  serviceAssertions =
    builtins.concatLists (map (name:
      let
        serviceCfg = cfg.services.${name};
        template = effectiveUnitTemplate name serviceCfg;
      in
      [
        {
          assertion = serviceCfg.replicas >= 0;
          message = "services.nix-swarm.services.${name}.replicas must be zero or greater";
        }
        {
          assertion = serviceCfg.replicas <= 1 || hasInfix "%{slot}" template;
          message = "services.nix-swarm.services.${name}.unitTemplate must include `%{slot}` when replicas > 1";
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
    ) (builtins.attrNames cfg.services));

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
      {command_timeout_ms, ${toString cfg.runtime.commandTimeoutMs}},
      {generation, ${toErlTerm cfg.runtime.generation}},
      {executor, [{adapter, systemd}]}
    ]}.
    {ingress, [
      ${concatMapStringsSep ",\n      " (entry: entry) (mapAttrsToList mkIngressEntry cfg.ingress.sites)}
    ]}.
  '';

  rawRenderedConfig = pkgs.writeText "nix-swarm.config.unvalidated" renderedConfigText;

  renderedConfig = pkgs.runCommand "nix-swarm.config" {} ''
    cp ${rawRenderedConfig} "$out"
    ${pkgs.erlang}/bin/erl -noshell -eval 'case file:consult("'$out'") of {ok, _Terms} -> halt(0); {error, Reason} -> io:format(standard_error, "invalid nix-swarm config: ~p~n", [Reason]), halt(1) end.'
  '';

  nodeHost = last (splitString "@" cfg.nodeName);

  releaseDistribution =
    if hasInfix "." nodeHost then
      "name"
    else
      "sname";

  swarmdStart = pkgs.writeShellScript "nix-swarmd-start" ''
    export NIX_SWARM_COOKIE="$(${pkgs.coreutils}/bin/tr -d '\n' < "$CREDENTIALS_DIRECTORY/nix-swarm-cookie")"
    exec ${cfg.package}/bin/nix-swarmd start
  '';
in
{
  imports = [ ./ingress.nix ];

  options.services.nix-swarm = {
    enable = mkEnableOption "the Nix-Swarm leaderless cluster runtime";

    package = mkOption {
      type = types.package;
      default = import ./package.nix { inherit pkgs; };
      description = "Package containing the Nix-Swarm node runtime (`bin/nix-swarmd`). The default compatibility package also includes the operator wrappers; release flakes additionally expose a dedicated `packages.<system>.cluster` output.";
    };

    nodeName = mkOption {
      type = types.str;
      description = "Distributed Erlang node name for this machine.";
    };

    cookieFile = mkOption {
      type = types.str;
      description = "Absolute path on the target machine to the Erlang cookie file used by all Nix-Swarm peers.";
    };

    epmdPort = mkOption {
      type = types.port;
      default = 4369;
      description = "TCP port used by epmd for Erlang node discovery.";
    };

    distributionPort = mkOption {
      type = types.port;
      default = 4370;
      description = "Fixed TCP port used by distributed Erlang for Nix-Swarm peer and operator connections.";
    };

    enableMDNS = mkOption {
      type = types.bool;
      default = false;
      description = "When enabled, publish each service via mDNS (Avahi) so services are discoverable as {service-name}.local.";
    };

    enableWatcher = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the auto-deploy file watcher as a systemd user service. Watches watchSource for changes and deploys automatically.";
    };

    watchSource = mkOption {
      type = types.str;
      default = "%h/.config/nix-swarm";
      description = "Directory to watch for config changes when enableWatcher is true. %h expands to the home directory.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to open the epmd and distributed Erlang TCP ports in the NixOS firewall.";
    };

    firewallInterfaces = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Optional interface names to scope the Nix-Swarm firewall ports to. Leave empty to open them on every interface when `openFirewall = true`.";
    };

    peers = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "All peer node names in the cluster.";
    };

    nodes = mkOption {
      type = types.attrsOf (types.submodule ({ ... }: {
        options = {
          labels = mkOption {
            type = types.listOf types.str;
            default = [];
          };

          deployHost = mkOption {
            type = types.str;
            description = "SSH host used by `nix-swarm update` when this node is live.";
          };
        };
      }));
      default = {};
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

          constraints = mkOption {
            type = types.listOf types.str;
            default = [];
          };

          allowedNodes = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Optional hard allowlist of peer node names. Empty means no hard node restriction.";
          };

          preferredNodes = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Preferred nodes for this service, listed in highest-to-lowest preference order.";
          };

          healthcheck = mkOption {
            type = types.nullOr types.str;
            default = null;
          };

          settings = mkOption {
            type = types.attrsOf (types.oneOf [ types.str types.int types.bool ]);
            default = {};
            description = "Extra service settings rendered into nix-swarm.config for service-specific runtime metadata.";
          };
        };
      }));
      default = {};
      description = "Cluster services keyed by logical service name.";
    };

    runtime = {
      connectIntervalMs = mkOption {
        type = types.int;
        default = 500;
      };

      reconcileIntervalMs = mkOption {
        type = types.int;
        default = 500;
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
    assertions = [
      {
        assertion = elem cfg.nodeName cfg.peers;
        message = "services.nix-swarm.nodeName must be included in services.nix-swarm.peers";
      }
      {
        assertion = all (peer: builtins.hasAttr peer cfg.nodes) cfg.peers;
        message = "every services.nix-swarm.peers entry must have matching services.nix-swarm.nodes metadata";
      }
      {
        assertion = all (peer: builtins.hasAttr peer cfg.nodes && cfg.nodes.${peer}.deployHost != "") cfg.peers;
        message = "every services.nix-swarm.nodes.<peer>.deployHost must be non-empty";
      }
    ] ++ serviceAssertions;

    networking.firewall = mkMerge [
      (mkIf (cfg.openFirewall && cfg.firewallInterfaces == []) {
        allowedTCPPorts = [ cfg.epmdPort cfg.distributionPort ];
      })
      (mkIf (cfg.openFirewall && cfg.firewallInterfaces != []) {
        interfaces = genAttrs cfg.firewallInterfaces (_: {
          allowedTCPPorts = [ cfg.epmdPort cfg.distributionPort ];
        });
      })
    ];

    services.avahi = mkIf cfg.enableMDNS {
      enable = true;
      nssmdns = true;
      publish.enable = true;
      publish.userServices = false;
      publish.domain = "local";
      extraServiceFiles =
        mkMerge (mapAttrsToList (name: serviceCfg:
          let
            ports = attrByPath [ "settings" "port" ] (attrByPath [ "settings" "http_port" ] 0 serviceCfg) serviceCfg;
            port = if builtins.isInt ports then ports else builtins.head ports;
          in
          mkIf (port > 0 && cfg.enableMDNS) {
            "${name}" = {
              name = name;
              serviceType = "_http._tcp";
              port = port;
              txtRecords = { "path" = "/"; };
            };
          }
        ) cfg.services) // {
          # Publish the nix-swarm node itself for auto-discovery
          nix-swarm = {
            name = "nix-swarm-${cfg.nodeName}";
            serviceType = "_nix-swarm._tcp";
            port = cfg.distributionPort;
            txtRecords = { "node" = cfg.nodeName; };
          };
        };
    };

    environment.systemPackages = [ cfg.package ];

    systemd.services.nix-swarmd = {
      description = "Nix-Swarm leaderless node runtime";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "notify";
        WatchdogSec = 30;
        Environment = [
          "NIX_SWARM_CONFIG_PATH=${renderedConfig}"
          "RELEASE_NODE=${cfg.nodeName}"
          "RELEASE_DISTRIBUTION=${releaseDistribution}"
          "ERL_EPMD_PORT=${toString cfg.epmdPort}"
          ''"ERL_AFLAGS=-kernel inet_dist_listen_min ${toString cfg.distributionPort} inet_dist_listen_max ${toString cfg.distributionPort}"''
          "NIX_SWARM_DISTRIBUTION_PORT=${toString cfg.distributionPort}"
        ];
        LoadCredential = [ "nix-swarm-cookie:${cfg.cookieFile}" ];
        ExecStart = swarmdStart;
        Restart = "always";
        RestartSec = 2;
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
      };
    };

    systemd.services.nix-swarm-watcher = mkIf cfg.enableWatcher {
      description = "Nix-Swarm auto-deploy file watcher";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/nix-swarm watch --source %h/.config/nix-swarm";
        Restart = "always";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };
  };
}
