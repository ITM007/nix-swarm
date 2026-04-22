{ config, lib, ... }:

let
  cfg = config.services.swarm;
  sites = cfg.ingress.sites;
  siteList = lib.mapAttrsToList (name: site: site // { _name = name; }) sites;
  peerHosts = map (peer: lib.last (lib.splitString "@" peer)) cfg.peers;

  serviceFor = site: lib.attrByPath [ site.service ] null cfg.services;

  portsFor = site:
    let
      service = serviceFor site;
    in
    if site.ports != [] then
      site.ports
    else if service == null || site.basePort == null then
      []
    else
      builtins.genList (index: site.basePort + index) service.replicas;

  upstreamName = site: "swarm_ingress_${site._name}";

  upstreamBlock = site:
    let
      upstreamEntries =
        lib.concatMapStringsSep "\n" (host:
          lib.concatMapStringsSep "\n" (port:
            "    server ${host}:${toString port} max_fails=3 fail_timeout=5s;"
          ) (portsFor site)
        ) peerHosts;
    in
    ''
      upstream ${upstreamName site} {
${upstreamEntries}
        keepalive 32;
      }
    '';

  vhostFor = site: {
    name = site.domain;
    value = {
      default = site.default;
      locations."/" = {
        proxyPass = "${site.scheme}://${upstreamName site}";
        proxyWebsockets = site.websocket;
      };
      extraConfig = ''
        client_max_body_size ${site.clientMaxBodySize};
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
${lib.optionalString (site.extraConfig != "") site.extraConfig}
      '';
    };
  };

  ingressAssertions =
    lib.concatMap (site:
      let
        service = serviceFor site;
      in
      [
        {
          assertion = service != null;
          message = "services.swarm.ingress.sites.${site._name} references unknown service `${site.service}`";
        }
        {
          assertion = site.ports != [] || site.basePort != null;
          message = "services.swarm.ingress.sites.${site._name} must set either `ports` or `basePort`";
        }
        {
          assertion = service == null || site.ports == [] || builtins.length site.ports == service.replicas;
          message = "services.swarm.ingress.sites.${site._name}.ports must match the replica count of `${site.service}`";
        }
      ]
    ) siteList;
in
{
  options.services.swarm.ingress = {
    sites = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
        options = {
          domain = lib.mkOption {
            type = lib.types.str;
            description = "Host name served by this ingress site.";
          };

          service = lib.mkOption {
            type = lib.types.str;
            description = "Swarm service name that backs this ingress site.";
          };

          basePort = lib.mkOption {
            type = lib.types.nullOr lib.types.port;
            default = null;
            description = "Base port used to derive one backend port per slot, e.g. 3000 => 3000, 3001, ...";
          };

          ports = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [];
            description = "Explicit backend ports to use instead of basePort.";
          };

          scheme = lib.mkOption {
            type = lib.types.enum [ "http" "https" ];
            default = "http";
          };

          websocket = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };

          clientMaxBodySize = lib.mkOption {
            type = lib.types.str;
            default = "64m";
          };

          default = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };

          extraConfig = lib.mkOption {
            type = lib.types.lines;
            default = "";
          };
        };
      }));
      default = {};
      description = "Small built-in nginx ingress helper for Swarm services.";
    };
  };

  config = lib.mkIf (sites != {}) {
    assertions = ingressAssertions;

    networking.firewall.allowedTCPPorts = [ 80 ];

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      appendHttpConfig = lib.concatMapStringsSep "\n" upstreamBlock siteList;
      virtualHosts = builtins.listToAttrs (map vhostFor siteList);
    };
  };
}
