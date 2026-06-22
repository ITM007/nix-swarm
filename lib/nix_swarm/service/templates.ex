defmodule NixSwarm.Service.Templates do
  @moduledoc """
  Pre-defined NixOS service templates for common services.
  Called via `nix-swarm service create --name <name> --template <type>`.
  """

  @templates %{
    "web" => %{
      description: "Generic web service (HTTP on port 8080)",
      filename: "{name}.nix",
      content: ~S'''
      { lib, ... }:
      let
        port = 8080;
      in
      {
        # systemd unit that backs this service
        systemd.services."{name}@" = {
          description = "{name} web service";
          wantedBy = lib.mkForce [];

          serviceConfig = {
            ExecStart = "${pkgs.bash}/bin/bash -lc 'port=$((port + %i)); exec ${pkgs.python3}/bin/python3 -m http.server \"$port\"'";
            Restart = "always";
            RestartSec = 5;
          };
        };

        # Firewall
        networking.firewall.allowedTCPPorts = [ port ];
      }
      '''
    },
    "gitea" => %{
      description: "Gitea Git service (port 3003)",
      filename: "{name}.nix",
      content: ~S'''
      { lib, ... }:
      {
        services.gitea.enable = true;
        services.gitea.stateDir = "/var/lib/gitea";
        services.gitea.settings.server.HTTP_PORT = 3003;
        services.gitea.settings.server.DOMAIN = "{name}.local";
        services.gitea.settings.server.ROOT_URL = "http://{name}.local:3003";

        systemd.services.gitea.wantedBy = lib.mkForce [];

        networking.firewall.allowedTCPPorts = [ 3003 ];
      }
      '''
    },
    "postgres" => %{
      description: "PostgreSQL database (port 5432)",
      filename: "{name}.nix",
      content: ~S'''
      { lib, ... }:
      {
        services.postgresql.enable = true;
        services.postgresql.authentication = "local all all trust\nhost all all 127.0.0.1/32 trust\nhost all all ::1/128 trust";

        systemd.services.postgresql.wantedBy = lib.mkForce [];

        networking.firewall.allowedTCPPorts = [ 5432 ];
      }
      '''
    },
    "nginx" => %{
      description: "Nginx reverse proxy (port 80)",
      filename: "{name}.nix",
      content: ~S'''
      { ... }:
      {
        services.nginx.enable = true;
        services.nginx.virtualHosts."{name}.local" = {
          locations."/" = {
            proxyPass = "http://127.0.0.1:8080";
          };
        };

        networking.firewall.allowedTCPPorts = [ 80 ];
      }
      '''
    },
    "custom" => %{
      description: "Minimal skeleton — fill in your own systemd unit",
      filename: "{name}.nix",
      content: ~S'''
      { lib, ... }:
      {
        # Replace this with your own systemd service
        systemd.services."{name}@" = {
          description = "{name} service managed by nix-swarm";
          wantedBy = lib.mkForce [];

          serviceConfig = {
            ExecStart = "${pkgs.bash}/bin/bash -c 'echo {name} running; sleep 10'";
            Restart = "always";
            RestartSec = 5;
          };
        };
      }
      '''
    }
  }

  def list do
    @templates
    |> Enum.map(fn {key, tpl} -> "#{key}: #{tpl.description}" end)
    |> Enum.join("\n")
  end

  def generate(template_name, service_name) do
    case Map.get(@templates, template_name) do
      nil ->
        {:error, "unknown template '#{template_name}'. Available:\n#{list()}"}

      tpl ->
        content =
          tpl.content
          |> String.replace("{name}", service_name)
          |> String.replace("{Name}", String.capitalize(service_name))

        filename = tpl.filename |> String.replace("{name}", service_name)
        {:ok, %{filename: filename, content: content, description: tpl.description}}
    end
  end
end
