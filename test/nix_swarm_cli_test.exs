defmodule NixSwarmCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "help output describes the TUI launcher and supported options" do
    output =
      capture_io(fn ->
        assert :ok == NixSwarm.CLI.run(["help"])
      end)

    assert output =~ "Launch the operator TUI"
    assert output =~ "nix-swarm --target NODE"
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
                 "nix-swarm@192.168.1.226",
                 "--cookie-file",
                 "/tmp/nix-swarm.cookie",
                 "--source",
                 "/tmp/nix-swarm"
               ],
               runner
             )

    assert_receive {:launched, opts}
    assert Keyword.get(opts, :target) == "nix-swarm@192.168.1.226"
    assert Keyword.get(opts, :cookie_file) == "/tmp/nix-swarm.cookie"
    assert Keyword.get(opts, :source) == "/tmp/nix-swarm"
  end

  test "legacy subcommands return a migration error" do
    assert {:error, message} = NixSwarm.CLI.run(["--target", "nix-swarm@192.168.1.226", "status"])

    assert message =~ "`status` was removed from the public command surface"
    assert message =~ "Nix-Swarm is TUI-first in v0.1.0 alpha"
    assert message =~ "nix-swarm --target NODE"
  end
end
