{ config, lib, pkgs, ... }:

let
  cfg = config.services.nix-swarm;
  inherit (lib) concatMapStringsSep genAttrs hasInfix last mapAttrsToList mkEnableOption mkIf mkMerge mkOption splitString types;

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
      {labels, ${mkStringList nodeCfg.labels}}${if nodeCfg.deployHost == null then "" else ",\n      {deploy_host, ${toErlTerm nodeCfg.deployHost}}"}
    ]}
  '';

  mkServiceEntry = name: serviceCfg: ''
      [
        {name, ${toErlTerm name}},
        {replicas, ${toString serviceCfg.replicas}},
        {unit_template, ${toErlTerm serviceCfg.unitTemplate}},
        {constraints, ${mkStringList serviceCfg.constraints}},
        {preferred_nodes, ${mkStringList serviceCfg.preferredNodes}},
        {healthcheck, ${toErlTerm serviceCfg.healthcheck}},
        {settings, ${toErlTerm serviceCfg.settings}}
      ]
    '';

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
    export RELEASE_COOKIE="$(${pkgs.coreutils}/bin/tr -d '\n' < "$CREDENTIALS_DIRECTORY/nix-swarm-cookie")"
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
      description = "Package containing the Nix-Swarm operator TUI (`bin/nix-swarm`) and node runtime (`bin/nix-swarmd`).";
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
            type = types.nullOr types.str;
            default = null;
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

    environment.systemPackages = [ cfg.package ];

    systemd.services.nix-swarmd = {
      description = "Nix-Swarm leaderless node runtime";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Environment = [
          "NIX_SWARM_CONFIG_PATH=${renderedConfig}"
          "RELEASE_NODE=${cfg.nodeName}"
          "RELEASE_DISTRIBUTION=${releaseDistribution}"
          "ERL_EPMD_PORT=${toString cfg.epmdPort}"
          ''"ERL_AFLAGS=-kernel inet_dist_listen_min ${toString cfg.distributionPort} inet_dist_listen_max ${toString cfg.distributionPort}"''
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
  };
}
