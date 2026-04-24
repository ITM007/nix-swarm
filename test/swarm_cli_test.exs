defmodule SwarmCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "help output describes the TUI launcher and supported options" do
    output =
      capture_io(fn ->
        assert :ok == Swarm.CLI.run(["help"])
      end)

    assert output =~ "Launch the operator TUI"
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
             Swarm.CLI.run(
               [
                 "--target",
                 "swarm@192.168.1.226",
                 "--cookie-file",
                 "/tmp/swarm.cookie",
                 "--source",
                 "/tmp/swarm"
               ],
               runner
             )

    assert_receive {:launched, opts}
    assert Keyword.get(opts, :target) == "swarm@192.168.1.226"
    assert Keyword.get(opts, :cookie_file) == "/tmp/swarm.cookie"
    assert Keyword.get(opts, :source) == "/tmp/swarm"
  end

  test "legacy subcommands return a migration error" do
    assert {:error, message} = Swarm.CLI.run(["--target", "swarm@192.168.1.226", "status"])

    assert message =~ "`status` was removed from the public command surface"
    assert message =~ "Swarm is TUI-first in v0.1.0 alpha"
    assert message =~ "swarm --target NODE"
  end
end
