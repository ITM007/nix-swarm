defmodule SwarmCLITest do
  use ExUnit.Case, async: true

  test "longname cli node identity uses the local host instead of the target host" do
    identity =
      Swarm.CLI.cli_node_identity("swarm@192.168.1.226", nil, fn _target_host ->
        "192.168.1.121"
      end)

    assert identity.mode == :longnames
    assert Atom.to_string(identity.name) =~ "@192.168.1.121"
    refute Atom.to_string(identity.name) =~ "@192.168.1.226"
  end

  test "run returns a formatted error when --name is invalid for a longname target" do
    assert {:error, message} =
             Swarm.CLI.run([
               "--target",
               "swarm@192.168.1.226",
               "--name",
               "swarmctl",
               "status"
             ])

    assert message == "--name must include @HOST when connecting to a longname target"
  end
end
