defmodule NixSwarmModuleStatefulTest do
  use ExUnit.Case, async: false

  @module_path "nix/nix-swarm/module.nix"

  test "restore wrapper extracts one declared directory with borgmatic extract" do
    result =
      eval_module!("""
        let
          packages = node.config.environment.systemPackages;
          wrapper = builtins.head (builtins.filter
            (package: builtins.match ".*nix-swarm-restore-db.*" package.name != null)
            packages);
        in {
          wrapper = builtins.readFile "${wrapper}/bin/nix-swarm-restore-db";
        }
      """)

    wrapper = result["wrapper"]
    assert wrapper =~ "borgmatic extract"
    refute wrapper =~ "borgmatic restore"
    assert wrapper =~ "--archive latest"
    assert wrapper =~ "archive_path=\"${source_dir#/}\""
    assert wrapper =~ "--path \"$archive_path\""
    assert wrapper =~ "--destination \"$staging_dir\""
    assert wrapper =~ "strip_components=3"
    assert wrapper =~ "strip_components=2"
    assert wrapper =~ "--strip-components \"$strip_components\""

    wrapper_path =
      Path.join(System.tmp_dir!(), "nix-swarm-restore-wrapper-#{System.unique_integer()}")

    File.write!(wrapper_path, wrapper)
    on_exit(fn -> File.rm(wrapper_path) end)
    assert System.cmd("bash", ["-n", wrapper_path]) == {"", 0}
  end

  defp eval_module!(body) do
    root = File.cwd!() |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    module_path = Path.join(root, @module_path)

    expression =
      """
      let
        flake = builtins.getFlake "#{root}";
        pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
        node = flake.inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            (import "#{module_path}")
            ({ ... }: {
              boot.loader.grub.devices = [ "nodev" ];
              fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
              system.stateVersion = "25.11";
              services.nix-swarm = {
                enable = true;
                package = pkgs.runCommand "nix-swarm-test-package" {} "mkdir -p $out/bin";
                nodeName = "nix-swarm@node-a.test";
                cookieFile = "/run/keys/nix-swarm.cookie";
                peers = [ "nix-swarm@node-a.test" ];
                nodes."nix-swarm@node-a.test".deployHost = "root@node-a.test";
                services.db = {
                  state = {
                    dirs = [ "/var/lib/db" "/srv/db uploads" ];
                    backup.target = "ssh://backup.example/./db";
                  };
                };
              };
            })
          ];
        };
      in #{body}
      """
      |> String.trim()

    case System.cmd("nix", ["eval", "--impure", "--json", "--expr", expression],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        json = Enum.find(String.split(output, "\n"), &String.starts_with?(&1, "{"))

        case JSON.decode(json || "") do
          {:ok, value} -> value
          {:error, _reason} -> flunk("nix eval returned non-JSON output:\n#{output}")
        end

      {output, status} ->
        flunk("nix eval failed with status #{status}:\n#{output}")
    end
  end
end
