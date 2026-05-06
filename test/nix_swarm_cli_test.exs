defmodule NixSwarmCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "help output describes the TUI launcher and supported options" do
    output =
      capture_io(fn ->
        assert :ok == NixSwarm.CLI.run(["help"])
      end)

    assert output =~ "Launch the operator TUI"
    assert output =~ "\n  swarm\n"
    assert output =~ "swarm --target NODE"
    assert output =~ "--cluster-file PATH"
    assert output =~ "--machines-dir PATH"
    assert output =~ "--services-dir PATH"
    assert output =~ "The old one-shot CLI subcommands were removed"
  end

  test "run delegates plain launches to the TUI runner" do
    test_pid = self()

    runner = fn opts ->
      send(test_pid, {:launched, opts})
      :ok
    end

    assert :ok ==
             NixSwarm.CLI.run(
               [
                 "--target",
                 "nix-swarm@example-node-a.local",
                 "--cookie-file",
                 "/tmp/nix-swarm.cookie",
                 "--source",
                 "/tmp/nix-swarm"
               ],
               runner
             )

    assert_receive {:launched, opts}
    assert Keyword.get(opts, :target) == "nix-swarm@example-node-a.local"
    assert Keyword.get(opts, :cookie_file) == "/tmp/nix-swarm.cookie"
    assert Keyword.get(opts, :source) == "/tmp/nix-swarm"
  end

  test "legacy subcommands return a migration error" do
    assert {:error, message} =
             NixSwarm.CLI.run(["--target", "nix-swarm@example-node-a.local", "status"])

    assert message =~ "`status` was removed from the public command surface"
    assert message =~ "Nix-Swarm is TUI-first in v0.3.1 alpha"
    assert message =~ "\n  swarm\n"
    assert message =~ "swarm --target NODE"
  end

  test "invalid numeric options return actionable errors" do
    assert {:error, "--lines must be a positive integer"} =
             NixSwarm.CLI.run(["--target", "nix-swarm@example-node-a.local", "--lines", "-1"])

    assert {:error, "--refresh-ms must be at least 100"} =
             NixSwarm.CLI.run([
               "--target",
               "nix-swarm@example-node-a.local",
               "--refresh-ms",
               "50"
             ])
  end

  test "run defaults target from cluster config when not provided" do
    root = Path.join(System.tmp_dir!(), "nix-swarm-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "cluster/services"))
    File.mkdir_p!(Path.join(root, "machines"))

    File.write!(
      Path.join(root, "cluster/cluster.nix"),
      """
      { ... }:
      {
          services.nix-swarm = {
            peers = [
            "swarm@198.51.100.10"
            ];
          };
        }
      """
    )

    on_exit(fn -> File.rm_rf!(root) end)

    test_pid = self()

    runner = fn opts ->
      send(test_pid, {:launched, opts})
      :ok
    end

    assert :ok == NixSwarm.CLI.run(["--source", root], runner)

    assert_receive {:launched, opts}
    assert Keyword.get(opts, :target) == "swarm@198.51.100.10"
  end
end
