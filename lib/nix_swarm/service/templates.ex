defmodule NixSwarm.Service.Templates do
  @moduledoc """
  Pre-defined NixOS service templates for common services.
  Called via `nix-swarm service create --name <name> --template <type>`.
  """

  @templates %{
    "web" => %{
      description: "Local example web service (ports 8080 + slot)",
      filename: "{name}.nix",
      content: ~S'''
      { lib, pkgs, ... }:
      let
        basePort = 8080;
      in
      {
        # Replace this example server with your packaged application.
        systemd.services."{name}@" = {
          description = "{name} web service";
          wantedBy = lib.mkForce [];

          serviceConfig = {
            DynamicUser = true;
            ExecStart = "${pkgs.bash}/bin/bash -c 'port=$(( ${toString basePort} + %i )); exec ${pkgs.python3}/bin/python3 -m http.server \"$port\" --bind 127.0.0.1 --directory /var/empty'";
            Restart = "on-failure";
            RestartSec = 5;
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
          };
        };
      }
      '''
    },
    "custom" => %{
      description: "Minimal skeleton — fill in your own systemd unit",
      filename: "{name}.nix",
      content: ~S'''
      { lib, pkgs, ... }:
      {
        # Replace this with your own systemd service
        systemd.services."{name}@" = {
          description = "{name} service managed by nix-swarm";
          wantedBy = lib.mkForce [];

          serviceConfig = {
            DynamicUser = true;
            ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
            Restart = "on-failure";
            RestartSec = 5;
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
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
