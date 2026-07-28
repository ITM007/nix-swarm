defmodule NixSwarmUpgradePhase4Test do
  use ExUnit.Case, async: true

  test "prepare updates only nix-swarm and leaves lock changes for review without deploying" do
    root = Path.join(System.tmp_dir!(), "nix-swarm-prepare-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "flake.nix"), "{ outputs = { self }: {}; }\n")
    File.write!(Path.join(root, "flake.lock"), "before\n")
    on_exit(fn -> File.rm_rf!(root) end)

    command_fun = fn executable, args, timeout ->
      send(self(), {:command, executable, args, timeout})
      File.write!(Path.join(root, "flake.lock"), "after\n")
      {"updated nix-swarm\n", 0}
    end

    result = NixSwarm.Upgrade.prepare([source: root, command_timeout_ms: 12_345], command_fun)

    assert result.source == root
    assert result.lock_output == "updated nix-swarm"
    assert result.lock_changed?
    assert File.read!(Path.join(root, "flake.lock")) == "after\n"
    assert_receive {:command, "nix", ["flake", "update", "nix-swarm", "--flake", ^root], 12_345}
  end

  test "prepare restores the exact lock file when validation fails" do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-prepare-fail-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "flake.nix"), "{ outputs = { self }: {}; }\n")
    File.write!(Path.join(root, "flake.lock"), "before\n")
    on_exit(fn -> File.rm_rf!(root) end)

    command_fun = fn _executable, _args, _timeout ->
      File.write!(Path.join(root, "flake.lock"), "after\n")
      {"updated", 0}
    end

    assert_raise RuntimeError, ~r/flake.lock was restored/, fn ->
      NixSwarm.Upgrade.prepare(
        [source: root, validate_fun: fn _ -> raise "invalid closure" end],
        command_fun
      )
    end

    assert File.read!(Path.join(root, "flake.lock")) == "before\n"
  end
end
