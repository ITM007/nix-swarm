defmodule NixSwarmConfigFilesTest do
  use ExUnit.Case, async: true

  alias NixSwarm.ConfigFiles

  setup do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-config-files-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "cluster/services"))
    File.mkdir_p!(Path.join(root, "machines"))
    File.mkdir_p!(Path.join(root, "nix/nix-swarm"))
    File.mkdir_p!(Path.join(root, "secrets"))

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

  test "default_target returns the first configured peer", %{paths: paths} do
    File.write!(
      paths.cluster_file,
      """
      { ... }:
        {
          services.nix-swarm = {
            peers = [
            "swarm@198.51.100.10"
            "swarm@198.51.100.11"
          ];
        };
      }
      """
    )

    assert ConfigFiles.default_target(paths) == "swarm@198.51.100.10"
  end

  test "local_cookie_file prefers a cookie under the source secrets directory", %{paths: paths} do
    cookie_path = Path.join(paths.source, "secrets/swarm.cookie")
    File.write!(cookie_path, "super-secret-cookie\n")

    assert ConfigFiles.local_cookie_file(paths) == cookie_path
  end

  test "add_machine creates a self-contained scaffold without rewriting cluster.nix", %{
    paths: paths
  } do
    assert {:ok, path} =
             ConfigFiles.add_machine(paths, "nix-swarm@10.0.0.2",
               deploy_host: "root@10.0.0.2",
               labels: ["apps", "ingress"]
             )

    contents = File.read!(path)
    assert contents =~ ~s(nodeName = "nix-swarm@10.0.0.2")
    assert contents =~ "(import ../nix/nix-swarm/module.nix)"
    assert contents =~ "../cluster/cluster.nix"
    assert contents =~ ~s("nix-swarm@10.0.0.2" = {)
    assert contents =~ ~s(labels = [ "apps" "ingress" ];)
    assert contents =~ ~s(deployHost = "root@10.0.0.2";)

    cluster = File.read!(paths.cluster_file)
    refute cluster =~ "nix-swarm@10.0.0.2"
  end

  test "add_machine escapes generated nix string values", %{paths: paths} do
    assert {:error, "node name contains unsupported characters"} =
             ConfigFiles.add_machine(paths, ~s(nix-swarm@10.0.0.2"${bad}))
  end

  test "add_service creates a declarative service scaffold without rewriting cluster.nix", %{
    paths: paths
  } do
    assert {:ok, path} =
             ConfigFiles.add_service(paths, "forgejo",
               replicas: 2,
               constraints: ["apps"],
               preferred_nodes: ["nix-swarm@10.0.0.1"],
               unit_template: "forgejo@%{slot}.service"
             )

    assert File.exists?(path)
    service_file = File.read!(path)
    assert service_file =~ ~s(services.nix-swarm.services."forgejo")
    assert service_file =~ "replicas = 2;"
    assert service_file =~ ~s(unitTemplate = "forgejo@%{slot}.service";)
    assert service_file =~ ~s(constraints = [ "apps" ];)
    assert service_file =~ ~s(preferredNodes = [ "nix-swarm@10.0.0.1" ];)

    cluster = File.read!(paths.cluster_file)
    refute cluster =~ "./services/forgejo.nix"
  end

  test "add_service rejects path traversal names", %{paths: paths} do
    assert {:error, "service name contains unsupported characters"} =
             ConfigFiles.add_service(paths, "../outside")

    refute File.exists?(Path.join(paths.source, "outside.nix"))
  end

  test "delete_machine removes the file and topology entry", %{paths: paths} do
    assert {:ok, path} =
             ConfigFiles.add_machine(paths, "nix-swarm@10.0.0.2",
               deploy_host: "root@10.0.0.2",
               labels: ["apps"]
             )

    assert {:ok, _path, warnings} = ConfigFiles.delete_machine(paths, path)

    refute File.exists?(path)
    cluster = File.read!(paths.cluster_file)
    refute cluster =~ ~s("nix-swarm@10.0.0.2";)
    refute cluster =~ ~s("nix-swarm@10.0.0.2" = {)
    assert [_ | _] = warnings
  end

  test "delete_service removes only the generated file and reports remaining references", %{
    paths: paths
  } do
    assert {:ok, _path} = ConfigFiles.add_service(paths, "forgejo", replicas: 1)

    File.write!(
      paths.cluster_file,
      File.read!(paths.cluster_file) <>
        """

          services.nix-swarm.ingress.sites.forgejo = {
            domain = "forgejo.test";
            service = "forgejo";
            ports = [ 3000 ];
          };
        """
    )

    assert File.read!(paths.cluster_file) =~ "ingress.sites.forgejo"

    assert {:ok, _path, warnings} = ConfigFiles.delete_service(paths, "gitea")

    refute File.exists?(Path.join(paths.services_dir, "gitea.nix"))
    assert File.read!(paths.cluster_file) =~ "./services/gitea.nix"
    assert warnings != []

    assert {:ok, _path, warnings} = ConfigFiles.delete_service(paths, "forgejo")
    cluster = File.read!(paths.cluster_file)
    assert cluster =~ "ingress.sites.forgejo"
    assert warnings != []
  end
end
