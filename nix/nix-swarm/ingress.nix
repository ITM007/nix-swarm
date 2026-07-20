{ config, lib, ... }:

let
  cfg = config.services.nix-swarm;
  sites = cfg.ingress.sites;
in
{
  options.services.nix-swarm.ingress = {
    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = "Compatibility metadata only; Nix-Swarm no longer configures an ingress listener.";
    };

    tls = {
      enableACME = lib.mkOption { type = lib.types.bool; default = false; };
      forceSSL = lib.mkOption { type = lib.types.bool; default = false; };
      email = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
    };

    sites = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = {
          domain = lib.mkOption { type = lib.types.str; };
          service = lib.mkOption { type = lib.types.str; };
          basePort = lib.mkOption { type = lib.types.nullOr lib.types.port; default = null; };
          ports = lib.mkOption { type = lib.types.listOf lib.types.port; default = [ ]; };
          scheme = lib.mkOption { type = lib.types.enum [ "http" "https" ]; default = "http"; };
          websocket = lib.mkOption { type = lib.types.bool; default = true; };
          clientMaxBodySize = lib.mkOption { type = lib.types.str; default = "64m"; };
          default = lib.mkOption { type = lib.types.bool; default = false; };
          extraConfig = lib.mkOption { type = lib.types.lines; default = ""; };
        };
      }));
      default = { };
      description = "Read-only routing metadata for an external Nix-managed load balancer.";
    };
  };

  config = lib.mkIf (sites != { }) {
    assertions = lib.mapAttrsToList
      (name: site: {
        assertion = builtins.hasAttr site.service cfg.services;
        message = "services.nix-swarm.ingress.sites.${name} references unknown service `${site.service}`";
      })
      sites;

    warnings = [
      "Nix-Swarm ingress sites are metadata-only; configure nginx, HAProxy, or another NixOS load balancer explicitly"
    ];
  };
}
