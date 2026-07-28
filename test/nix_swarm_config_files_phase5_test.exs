defmodule NixSwarmConfigFilesPhase5Test do
  use ExUnit.Case, async: true

  alias NixSwarm.ConfigFiles

  test "generated machine and service paths are always Nix files" do
    root = Path.join(System.tmp_dir!(), "nix-swarm-phase5-#{System.unique_integer([:positive])}")
    paths = ConfigFiles.defaults(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert ConfigFiles.generated_path_allowed?(Path.join(paths.machines_dir, "node-c.nix"))
    assert ConfigFiles.generated_path_allowed?(Path.join(paths.services_dir, "web.nix"))
    refute ConfigFiles.generated_path_allowed?(Path.join(paths.machines_dir, "node-c.json"))
    refute ConfigFiles.generated_path_allowed?(Path.join(paths.services_dir, "web.yaml"))
    refute ConfigFiles.generated_path_allowed?(Path.join(root, "secrets/cookie"))
  end
end
