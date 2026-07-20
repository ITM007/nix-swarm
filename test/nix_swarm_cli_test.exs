defmodule NixSwarmCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "help output describes code-first commands and the read-only TUI" do
    output =
      capture_io(fn ->
        assert :ok == NixSwarm.CLI.run(["help"])
      end)

    assert output =~ "read-only operator TUI"
    assert output =~ "\n  nix-swarm\n"
    assert output =~ "nix-swarm --target NODE"
    assert output =~ "--cluster-file PATH"
    assert output =~ "--machines-dir PATH"
    assert output =~ "--services-dir PATH"
    assert output =~ "nix-swarm cluster plan"
    assert output =~ "nix-swarm cluster apply"
    assert output =~ "Nix code is the only desired-state mutation interface"
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
                 "--ssh-host",
                 "operator@example-node-a.local",
                 "--source",
                 "/tmp/nix-swarm"
               ],
               runner
             )

    assert_receive {:launched, opts}
    assert Keyword.get(opts, :target) == "nix-swarm@example-node-a.local"
    assert Keyword.get(opts, :ssh_host) == "operator@example-node-a.local"
    assert Keyword.get(opts, :source) == "/tmp/nix-swarm"
  end

  test "unknown subcommands return a code-first usage error" do
    assert {:error, message} =
             NixSwarm.CLI.run(["--target", "nix-swarm@example-node-a.local", "status"])

    assert message =~ "Unknown command: `status`"
    assert message =~ "Nix-Swarm is code-first"
    assert message =~ "\n  nix-swarm\n"
    assert message =~ "nix-swarm --target NODE"
  end

  test "apply requires an explicit confirmation flag" do
    assert {:error, message} = NixSwarm.CLI.run(["cluster", "apply"])
    assert message =~ "repeat with --yes"
  end

  test "plan renders the code-defined Nix deployment without mutation" do
    source = Path.expand("..", __DIR__)

    output =
      capture_io(fn ->
        assert :ok =
                 NixSwarm.CLI.run(
                   ["cluster", "plan", "--source", source],
                   fn _ -> flunk("TUI must not launch") end,
                   plan_fun: &NixSwarm.Deploy.plan/1
                 )
      end)

    assert output =~ "NixOS deployment plan"
    assert output =~ "nixosConfigurations"
    assert output =~ "nixos-rebuild"
  end

  test "confirmed apply delegates to the native deployment boundary" do
    source = Path.expand("..", __DIR__)
    test_pid = self()

    deploy_fun = fn opts ->
      send(test_pid, {:deploy_opts, opts})
      NixSwarm.Deploy.plan(opts)
    end

    capture_io(fn ->
      assert :ok =
               NixSwarm.CLI.run(
                 ["cluster", "apply", "--source", source, "--yes"],
                 fn _ -> flunk("TUI must not launch") end,
                 deploy_fun: deploy_fun
               )
    end)

    assert_receive {:deploy_opts, opts}
    refute Keyword.fetch!(opts, :dry_run)
  end

  test "invalid numeric options return actionable errors" do
    assert {:error, "--lines must be between 1 and 1000"} =
             NixSwarm.CLI.run(["--target", "nix-swarm@example-node-a.local", "--lines", "-1"])

    assert {:error, "--refresh-ms must be between 100 and 600000"} =
             NixSwarm.CLI.run([
               "--target",
               "nix-swarm@example-node-a.local",
               "--refresh-ms",
               "50"
             ])

    assert {:error, "--replicas must be between 0 and 128"} =
             NixSwarm.CLI.run(["service", "add", "--name", "web", "--replicas", "129"])
  end

  test "service create honors the selected code-first source tree" do
    root = Path.join(System.tmp_dir!(), "nix-swarm-service-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "services"))
    on_exit(fn -> File.rm_rf!(root) end)

    output =
      capture_io(fn ->
        assert :ok ==
                 NixSwarm.CLI.run([
                   "service",
                   "create",
                   "--source",
                   root,
                   "--name",
                   "example"
                 ])
      end)

    assert output =~ Path.join(root, "services/example.nix")
    assert File.exists?(Path.join(root, "services/example.nix"))
  end

  test "service add creates a matching instance unit in the selected source tree" do
    root = Path.join(System.tmp_dir!(), "nix-swarm-add-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "services"))
    File.mkdir_p!(Path.join(root, "machines"))

    File.cp!(
      Path.expand("../examples/starter/cluster.nix", __DIR__),
      Path.join(root, "cluster.nix")
    )

    on_exit(fn -> File.rm_rf!(root) end)

    capture_io(fn ->
      assert :ok ==
               NixSwarm.CLI.run([
                 "service",
                 "add",
                 "--source",
                 root,
                 "--name",
                 "worker",
                 "--template",
                 "custom",
                 "--replicas",
                 "2"
               ])
    end)

    service_file = File.read!(Path.join(root, "services/worker.nix"))
    assert service_file =~ ~s(unitTemplate = "worker@%{slot}.service";)
    assert service_file =~ "replicas = 2;"
    assert service_file =~ ~s(systemd.services."worker@")
  end

  test "cluster init returns an error when activation does not converge" do
    source = Path.expand("..", __DIR__)

    credentials_fun = fn _opts ->
      %{fingerprint: "0123456789ab", hosts: ["root@node-a"]}
    end

    ensure_fun = fn _opts ->
      %{ok: false, nodes: [%{node: "node-a", status: :error, message: "activation failed"}]}
    end

    output =
      capture_io(fn ->
        assert {:error, "some nodes failed; see above"} ==
                 NixSwarm.CLI.run(
                   ["cluster", "init", "--source", source, "--yes"],
                   fn _ -> flunk("TUI must not launch") end,
                   credentials_fun: credentials_fun,
                   ensure_fun: ensure_fun
                 )
      end)

    assert output =~ "activation failed"
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

  test "run defaults SSH access from code-defined deployment metadata" do
    source = Path.expand("../examples/starter", __DIR__)
    test_pid = self()

    runner = fn opts ->
      send(test_pid, {:launched, opts})
      :ok
    end

    assert :ok == NixSwarm.CLI.run(["--source", source], runner)
    assert_receive {:launched, opts}
    assert Keyword.get(opts, :target) == "nix-swarm@node-a"
    assert Keyword.get(opts, :ssh_host) == "root@node-a"
  end
end
