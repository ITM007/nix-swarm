{ config, lib, pkgs, ... }:

let
  cfg = config.services.swarm;
  inherit (lib) concatMapStringsSep hasInfix last mapAttrsToList mkEnableOption mkIf mkOption splitString types;

  toErlTerm =
    value:
    if value == null then
      "undefined"
    else if builtins.isBool value then
      if value then "true" else "false"
    else if builtins.isInt value then
      toString value
    else if builtins.isString value then
      "\"${value}\""
    else if builtins.isList value then
      "[${concatMapStringsSep ", " toErlTerm value}]"
    else if builtins.isAttrs value then
      "[${concatMapStringsSep ", " (name: "{${name}, ${toErlTerm value.${name}}}") (builtins.attrNames value)}]"
    else
      throw "unsupported Erlang term conversion in swarm-module.nix";

  mkStringList = values:
    "[${concatMapStringsSep ", " (value: "\"${value}\"") values}]";

  mkPeerAtoms = peers:
    "[${concatMapStringsSep ", " (peer: "'${peer}'") peers}]";

  mkNodeEntry = name: nodeCfg: ''
    {'${name}', [{labels, ${mkStringList nodeCfg.labels}}]}
  '';

  mkServiceEntry = name: serviceCfg: ''
    [
      {name, "${name}"},
      {replicas, ${toString serviceCfg.replicas}},
      {unit_template, "${serviceCfg.unitTemplate}"},
      {constraints, ${mkStringList serviceCfg.constraints}},
      {healthcheck, ${if serviceCfg.healthcheck == null then "undefined" else "\"${serviceCfg.healthcheck}\""}},
      {settings, ${toErlTerm serviceCfg.settings}}
    ]
  '';

  renderedConfig = pkgs.writeText "swarm.config" ''
    {peers, ${mkPeerAtoms cfg.peers}}.
    {nodes, [
      ${concatMapStringsSep ",\n      " (entry: entry) (mapAttrsToList mkNodeEntry cfg.nodes)}
    ]}.
    {services, [
      ${concatMapStringsSep ",\n      " (entry: entry) (mapAttrsToList mkServiceEntry cfg.services)}
    ]}.
    {runtime, [
      {connect_interval_ms, ${toString cfg.runtime.connectIntervalMs}},
      {reconcile_interval_ms, ${toString cfg.runtime.reconcileIntervalMs}},
      {generation, "${cfg.runtime.generation}"},
      {executor, [{adapter, systemd}]}
    ]}.
  '';

  nodeHost = last (splitString "@" cfg.nodeName);

  releaseDistribution =
    if hasInfix "." nodeHost then
      "name"
    else
      "sname";
in
{
  imports = [ ./ingress.nix ];

  options.services.swarm = {
    enable = mkEnableOption "the Swarm leaderless cluster runtime";

    package = mkOption {
      type = types.package;
      description = "Package containing the Swarm release with bin/swarm.";
    };

    nodeName = mkOption {
      type = types.str;
      description = "Distributed Erlang node name for this machine.";
    };

    cookieFile = mkOption {
      type = types.path;
      description = "Path to the Erlang cookie file used by all Swarm peers.";
    };

    epmdPort = mkOption {
      type = types.port;
      default = 4369;
      description = "TCP port used by epmd for Erlang node discovery.";
    };

    distributionPort = mkOption {
      type = types.port;
      default = 4370;
      description = "Fixed TCP port used by distributed Erlang for Swarm peer and CLI connections.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to open the epmd and distributed Erlang TCP ports in the NixOS firewall.";
    };

    peers = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "All peer node names in the cluster.";
    };

    nodes = mkOption {
      type = types.attrsOf (types.submodule ({ ... }: {
        options.labels = mkOption {
          type = types.listOf types.str;
          default = [];
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
            type = types.str;
            description = "Systemd unit template rendered by Swarm, e.g. gitea@%{slot}.service.";
          };

          constraints = mkOption {
            type = types.listOf types.str;
            default = [];
          };

          healthcheck = mkOption {
            type = types.nullOr types.str;
            default = null;
          };

          settings = mkOption {
            type = types.attrsOf (types.oneOf [ types.str types.int types.bool ]);
            default = {};
            description = "Extra service settings rendered into swarm.config for service-specific runtime metadata.";
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

      generation = mkOption {
        type = types.str;
        default = "nixos";
      };
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts =
      mkIf cfg.openFirewall [ cfg.epmdPort cfg.distributionPort ];

    systemd.services.swarmd = {
      description = "Swarm leaderless node runtime";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Environment = [
          "SWARM_CONFIG_PATH=${renderedConfig}"
          "RELEASE_NODE=${cfg.nodeName}"
          "RELEASE_COOKIE=${builtins.readFile cfg.cookieFile}"
          "RELEASE_DISTRIBUTION=${releaseDistribution}"
          "ERL_EPMD_PORT=${toString cfg.epmdPort}"
          ''"ERL_AFLAGS=-kernel inet_dist_listen_min ${toString cfg.distributionPort} inet_dist_listen_max ${toString cfg.distributionPort}"''
        ];
        ExecStart = "${cfg.package}/bin/swarm start";
        Restart = "always";
        RestartSec = 2;
      };
    };
  };
}
