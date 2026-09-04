defmodule NixSwarmUpgradeTest do
  use ExUnit.Case, async: true

  defp fake_query(overrides \\ %{}) do
    base = %{
      protocol_version: NixSwarm.QueryProtocol.protocol_version(),
      source_digest: NixSwarm.API.source_digest()
    }

    fn _remote, _request -> {:ok, Map.merge(base, overrides)} end
  end

  test "updates only the nix-swarm input before using the normal deploy path" do
    source = Path.expand("..", __DIR__)
    test_pid = self()

    command_fun = fn executable, args, timeout_ms ->
      send(test_pid, {:command, executable, args, timeout_ms})
      {"updated lock file\n", 0}
    end

    deploy_fun = fn opts ->
      send(test_pid, {:deploy, opts})
      %{dry_run: false, results: []}
    end

    result =
      NixSwarm.Upgrade.run(
        [source: source, command_timeout_ms: 12_345],
        deploy_fun,
        command_fun
      )

    assert result.source == source
    assert result.lock_output == "updated lock file"
    assert result.deploy == %{dry_run: false, results: []}

    assert_receive {:command, "nix", ["flake", "update", "nix-swarm", "--flake", ^source], 12_345}

    assert_receive {:deploy, opts}
    assert Keyword.fetch!(opts, :source) == source
  end

  test "fails closed when updating the lock file fails" do
    source = Path.expand("..", __DIR__)
    command_fun = fn _executable, _args, _timeout -> {"network failed", 1} end

    assert_raise RuntimeError, ~r/failed to update.*network failed/, fn ->
      NixSwarm.Upgrade.run(
        [source: source],
        fn _ -> flunk("deploy must not run") end,
        command_fun
      )
    end
  end

  test "rejects a source without a flake" do
    root = Path.join(System.tmp_dir!(), "nix-swarm-upgrade-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert_raise ArgumentError, ~r/flake.nix does not exist/, fn ->
      NixSwarm.Upgrade.run([source: root], fn _ -> :ok end, fn _, _, _ -> {"", 0} end)
    end
  end

  test "restores flake.lock when deployment fails" do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-upgrade-lock-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "flake.nix"), "{ outputs = { self }: {}; }\n")
    File.write!(Path.join(root, "flake.lock"), "before\n")
    on_exit(fn -> File.rm_rf!(root) end)

    command_fun = fn _executable, _args, _timeout ->
      File.write!(Path.join(root, "flake.lock"), "after\n")
      {"updated", 0}
    end

    assert_raise RuntimeError, ~r/flake.lock was restored/, fn ->
      NixSwarm.Upgrade.run(
        [source: root],
        fn _opts -> raise "deployment failed" end,
        command_fun
      )
    end

    assert File.read!(Path.join(root, "flake.lock")) == "before\n"
  end

  test "upgrade rejects protocol-incompatible agents before deploy" do
    source = Path.expand("..", __DIR__)
    test_pid = self()

    command_fun = fn _executable, _args, _timeout -> {"updated", 0} end

    deploy_fun = fn _opts ->
      send(test_pid, :deployed)
      %{dry_run: false, results: []}
    end

    assert_raise RuntimeError, ~r/upgrade blocked.*protocol/, fn ->
      NixSwarm.Upgrade.run(
        [source: source, hosts: ["root@node-a"], query_fun: fake_query(%{protocol_version: 1})],
        deploy_fun,
        command_fun
      )
    end

    refute_received :deployed
  end

  test "upgrade rejects agents built from a different source tree before deploy" do
    source = Path.expand("..", __DIR__)
    test_pid = self()

    command_fun = fn _executable, _args, _timeout -> {"updated", 0} end

    deploy_fun = fn _opts ->
      send(test_pid, :deployed)
      %{dry_run: false, results: []}
    end

    assert_raise RuntimeError, ~r/upgrade blocked.*source tree/, fn ->
      NixSwarm.Upgrade.run(
        [
          source: source,
          hosts: ["root@node-a"],
          query_fun: fake_query(%{source_digest: String.duplicate("f", 64)})
        ],
        deploy_fun,
        command_fun
      )
    end

    refute_received :deployed
  end

  test "compatible agents proceed through the gated upgrade path" do
    source = Path.expand("..", __DIR__)
    test_pid = self()

    command_fun = fn _executable, _args, _timeout -> {"updated", 0} end

    deploy_fun = fn opts ->
      send(test_pid, {:deployed, Keyword.get(opts, :hosts)})
      %{dry_run: false, results: []}
    end

    result =
      NixSwarm.Upgrade.run(
        [source: source, hosts: ["root@node-a"], query_fun: fake_query()],
        deploy_fun,
        command_fun
      )

    assert_received {:deployed, ["root@node-a"]}
    assert result.deploy == %{dry_run: false, results: []}
  end

  test "a blocked protocol gate restores flake.lock" do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-upgrade-gate-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "flake.nix"), "{ outputs = { self }: {}; }\n")
    File.write!(Path.join(root, "flake.lock"), "before\n")
    on_exit(fn -> File.rm_rf!(root) end)

    command_fun = fn _executable, _args, _timeout ->
      File.write!(Path.join(root, "flake.lock"), "after\n")
      {"updated", 0}
    end

    assert_raise RuntimeError, ~r/flake.lock was restored/, fn ->
      NixSwarm.Upgrade.run(
        [source: root, hosts: ["root@node-a"], query_fun: fake_query(%{protocol_version: 1})],
        fn _opts -> flunk("deploy must not run") end,
        command_fun
      )
    end

    assert File.read!(Path.join(root, "flake.lock")) == "before\n"
  end
end
