defmodule NixSwarmConfigFilesTest do
  use ExUnit.Case, async: true

  alias NixSwarm.ConfigFiles

  setup do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-config-files-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "cluster/services"))
    File.mkdir_p!(Path.join(root, "machines"))
    File.mkdir_p!(Path.join(root, "nix/nix-swarm"))

    File.write!(
      Path.join(root, "cluster/cluster.nix"),
      """
      { ... }:
      {
        imports = [
          ./services/gitea.nix
        ];
      }
      """
    )

    File.write!(Path.join(root, "cluster/services/gitea.nix"), "{ ... }: { }\n")
    File.write!(Path.join(root, "nix/nix-swarm/module.nix"), "{ ... }: { }\n")

    File.write!(
      Path.join(root, "machines/node-a.nix"),
      """
      { inputs, pkgs, ... }:
      {
        imports = [
          (import ../nix/nix-swarm/module.nix)
          ../cluster/cluster.nix
        ];

        services.nix-swarm = {
          enable = true;
          nodeName = "nix-swarm@10.0.0.1";
          cookieFile = "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie";
        };
      }
      """
    )

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root, paths: ConfigFiles.defaults(root)}
  end

  test "machine_file_for_node resolves machine files by node name", %{paths: paths} do
    path = ConfigFiles.machine_file_for_node(paths, "nix-swarm@10.0.0.1")

    assert path =~ "node-a.nix"
    assert ConfigFiles.machine_node_name(path) == "nix-swarm@10.0.0.1"
  end

  test "add_machine creates a machine file with relative imports", %{paths: paths} do
    assert {:ok, path} = ConfigFiles.add_machine(paths, "nix-swarm@10.0.0.2")

    contents = File.read!(path)
    assert contents =~ ~s(nodeName = "nix-swarm@10.0.0.2")
    assert contents =~ "(import ../nix/nix-swarm/module.nix)"
    assert contents =~ "../cluster/cluster.nix"
  end

  test "add_machine escapes generated nix string values", %{paths: paths} do
    assert {:error, "node name contains unsupported characters"} =
             ConfigFiles.add_machine(paths, ~s(nix-swarm@10.0.0.2"${bad}))
  end

  test "add_service creates a service file and imports it from cluster.nix", %{paths: paths} do
    assert {:ok, path} = ConfigFiles.add_service(paths, "forgejo")

    assert File.exists?(path)
    assert File.read!(paths.cluster_file) =~ "./services/forgejo.nix"
  end

  test "add_service rejects path traversal names", %{paths: paths} do
    assert {:error, "service name contains unsupported characters"} =
             ConfigFiles.add_service(paths, "../outside")

    refute File.exists?(Path.join(paths.source, "outside.nix"))
  end

  test "delete_service removes the file and import line", %{paths: paths} do
    assert {:ok, _path, warnings} = ConfigFiles.delete_service(paths, "gitea")

    refute File.exists?(Path.join(paths.services_dir, "gitea.nix"))
    refute File.read!(paths.cluster_file) =~ "./services/gitea.nix"
    assert warnings == []
  end
end
