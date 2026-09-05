defmodule NixSwarmDaemonEntryTest do
  use ExUnit.Case, async: false

  test "nix-swarmd proxy starts the proxy role through the real release entrypoint" do
    root = File.cwd!()

    config_path =
      Path.join(System.tmp_dir!(), "nix-swarmd-proxy-#{System.unique_integer([:positive])}.terms")

    File.write!(config_path, "{listen_port, 40123}.\n{routes, []}.\n")

    on_exit(fn -> File.rm(config_path) end)

    {package_path, 0} =
      System.cmd("nix", ["build", "--no-link", "--print-out-paths", ".#nix-swarm"], cd: root)

    package_path = String.trim(package_path)

    {output, status} =
      System.cmd(
        "timeout",
        ["5", Path.join(package_path, "bin/nix-swarmd"), "proxy"],
        env: [{"NIX_SWARM_PROXY_CONFIG_PATH", config_path}],
        stderr_to_stdout: true,
        cd: root
      )

    assert status == 124, "proxy daemon exited instead of staying alive:\n#{output}"
    refute output =~ "NIX_SWARM_CONFIG_PATH"
    refute output =~ "invalid runtime role"
  end
end
