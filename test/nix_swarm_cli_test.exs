defmodule NixSwarmCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "help output describes code-first commands and the read-only TUI" do
    output =
      capture_io(fn ->
        assert :ok == NixSwarm.CLI.run(["help"])
      end)

    assert output =~ "Read-only operator TUI"
    assert output =~ "\n  nix-swarm\n"
    assert output =~ "nix-swarm --target NODE"
    assert output =~ "--cluster-file PATH"
    assert output =~ "--machines-dir PATH"
    assert output =~ "--services-dir PATH"
    assert output =~ "nix-swarm cluster plan"
    assert output =~ "nix-swarm cluster apply"
    assert output =~ "nix-swarm service restart --name SERVICE --target NODE --yes"
    assert output =~ "--allow-dirty              deploy an uncommitted source tree"
    assert output =~ "refuses an uncommitted source tree unless --allow-dirty"
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

  test "removed commands return concise migration errors" do
    root = Path.join(System.tmp_dir!(), "nix-swarm-removed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for {argv, migration} <- [
          {["cluster", "init"], "cluster apply"},
          {["cluster", "ensure"], "cluster apply"},
          {["cluster", "rebuild"], "cluster apply"},
          {["cluster", "members"], "cluster status"},
          {["cluster", "credentials"], "cluster credentials rotate"},
          {["cluster", "upgrade", "prepare"], "cluster upgrade"},
          {["service", "create", "--source", root, "--name", "example"], "examples/starter"},
          {["service", "add", "--source", root, "--name", "example"], "examples/starter"},
          {["service", "list"], "examples/starter"}
        ] do
      assert {:error, message} = NixSwarm.CLI.run(argv)
      assert message =~ "removed"
      assert message =~ migration
      refute message =~ "Ensuring cluster"
      refute message =~ "Available service templates"
    end
  end

  test "service restart requires an explicit confirmation flag" do
    assert {:error, message} =
             NixSwarm.CLI.run(["service", "restart", "--name", "demo", "--target", "node@host"])

    assert message =~ "service restart changes machines"
    assert message =~ "repeat with --yes"
  end

  test "apply requires an explicit confirmation flag" do
    assert {:error, message} = NixSwarm.CLI.run(["cluster", "apply"])
    assert message =~ "repeat with --yes"
  end

  test "json is rejected for commands that do not define a json output contract" do
    assert {:error, message} = NixSwarm.CLI.run(["service", "list", "--json"])
    assert message =~ "--json is supported only for cluster status"
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

  test "confirmed apply forwards --allow-dirty to the deployment boundary" do
    source = Path.expand("..", __DIR__)
    test_pid = self()

    deploy_fun = fn opts ->
      send(test_pid, {:deploy_opts, opts})

      %{
        source: source,
        validation: %{commands: []},
        batches: [],
        dry_run: false,
        results: []
      }
    end

    capture_io(fn ->
      assert :ok =
               NixSwarm.CLI.run(
                 ["cluster", "apply", "--source", source, "--yes", "--allow-dirty"],
                 fn _ -> flunk("TUI must not launch") end,
                 deploy_fun: deploy_fun
               )
    end)

    assert_receive {:deploy_opts, opts}
    assert Keyword.fetch!(opts, :allow_dirty)
  end

  test "confirmed rollback preserves the deployment options it accepts" do
    test_pid = self()

    rollback_fun = fn opts ->
      send(test_pid, {:rollback_opts, opts})

      %{
        source: "/tmp/nix-swarm",
        validation: %{commands: []},
        batches: [],
        dry_run: false,
        results: []
      }
    end

    capture_io(fn ->
      assert :ok =
               NixSwarm.CLI.run(
                 [
                   "cluster",
                   "rollback",
                   "--source",
                   "/tmp/nix-swarm",
                   "--cluster-file",
                   "/tmp/nix-swarm/cluster.nix",
                   "--machines-dir",
                   "/tmp/nix-swarm/machines",
                   "--flake",
                   "/tmp/nix-swarm",
                   "--host",
                   "root@node-a",
                   "--command-timeout-ms",
                   "1234",
                   "--secret-file",
                   "/tmp/nix-swarm/secret",
                   "--allow-dirty",
                   "--yes"
                 ],
                 fn _ -> flunk("TUI must not launch") end,
                 rollback_fun: rollback_fun
               )
    end)

    assert_receive {:rollback_opts, opts}
    assert Keyword.get(opts, :source) == "/tmp/nix-swarm"
    assert Keyword.get(opts, :cluster_file) == "/tmp/nix-swarm/cluster.nix"
    assert Keyword.get(opts, :machines_dir) == "/tmp/nix-swarm/machines"
    assert Keyword.get(opts, :flake) == "/tmp/nix-swarm"
    assert Keyword.get(opts, :host) == "root@node-a"
    assert Keyword.get(opts, :command_timeout_ms) == 1234
    assert Keyword.get(opts, :secret_file) == "/tmp/nix-swarm/secret"
    assert Keyword.get(opts, :allow_dirty)
    assert Keyword.get(opts, :dry_run) == false
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

  defp heal_query_fun(overview) do
    fn
      _remote, :cluster_members -> {:ok, %{}}
      _remote, :cluster_overview -> {:ok, overview}
      _remote, _request -> {:ok, %{}}
    end
  end

  defp heal_overview(state_contracts) do
    %{
      members: %{
        configured_nodes: [:"db@127.0.0.1", :"db@127.0.0.2"],
        deploy_hosts: %{:"db@127.0.0.1" => "root@db-1", :"db@127.0.0.2" => "root@db-2"}
      },
      status: %{
        placements: %{db: [%{unit: "db.service", owner: :"db@127.0.0.1", slot: 0}]},
        state_contracts: state_contracts
      }
    }
  end

  defp heal_deps(overview, heal_fun, test_pid) do
    [
      query_fun: heal_query_fun(overview),
      heal_fun: fn opts ->
        send(test_pid, {:heal_opts, opts})
        heal_fun.(opts)
      end
    ]
  end

  defp db_contract(overrides \\ %{}) do
    Map.merge(
      %{
        dirs: ["/var/lib/db"],
        restore: "borg-latest",
        auto_heal: false,
        heal_grace_sec: 600
      },
      overrides
    )
  end

  test "cluster heal requires an explicit confirmation flag" do
    assert {:error, message} = NixSwarm.CLI.run(["cluster", "heal", "db"])
    assert message =~ "cluster heal restores backup state"
    assert message =~ "repeat with --yes"
  end

  test "cluster heal reports unknown services from the cluster overview" do
    test_pid = self()
    deps = heal_deps(heal_overview(%{}), fn _ -> flunk("heal must not run") end, test_pid)

    assert {:error, message} =
             NixSwarm.CLI.run(
               ["cluster", "heal", "nope", "--target", "db@127.0.0.1", "--yes"],
               fn _opts -> :ok end,
               deps
             )

    assert message =~ "unknown service \"nope\""
    refute_received {:heal_opts, _}
  end

  test "cluster heal rejects a service without a state contract" do
    test_pid = self()
    overview = heal_overview(%{})
    deps = heal_deps(overview, fn _ -> flunk("heal must not run") end, test_pid)

    assert {:error, message} =
             NixSwarm.CLI.run(
               ["cluster", "heal", "db", "--target", "db@127.0.0.1", "--yes"],
               fn _opts -> :ok end,
               deps
             )

    assert message =~ "db\" is not stateful"
    refute_received {:heal_opts, _}
  end

  test "cluster heal refuses a service whose restore strategy is none" do
    test_pid = self()
    overview = heal_overview(%{db: db_contract(%{restore: "none"})})
    deps = heal_deps(overview, fn _ -> flunk("heal must not run") end, test_pid)

    assert {:error, message} =
             NixSwarm.CLI.run(
               ["cluster", "heal", "db", "--target", "db@127.0.0.1", "--yes"],
               fn _opts -> :ok end,
               deps
             )

    assert message =~ "restore \"none\""
    refute_received {:heal_opts, _}
  end

  test "cluster heal defaults to the placement owner and its deploy host" do
    test_pid = self()
    overview = heal_overview(%{db: db_contract()})

    deps =
      heal_deps(
        overview,
        fn _opts ->
          {:ok,
           %{service: "db", unit: "db.service", host: "root@db-1", restored: ["/var/lib/db"]}}
        end,
        test_pid
      )

    assert :ok =
             NixSwarm.CLI.run(
               ["cluster", "heal", "db", "--target", "db@127.0.0.1", "--yes"],
               fn _opts -> :ok end,
               deps
             )

    assert_received {:heal_opts, opts}
    assert Keyword.fetch!(opts, :service) == "db"
    assert Keyword.fetch!(opts, :unit) == "db.service"
    assert Keyword.fetch!(opts, :dirs) == ["/var/lib/db"]
    assert Keyword.fetch!(opts, :node) == :"db@127.0.0.1"
    assert Keyword.fetch!(opts, :host) == "root@db-1"
    assert is_function(Keyword.fetch!(opts, :command_fun), 2)
  end

  test "cluster heal rejects a node that is not the placement owner" do
    test_pid = self()
    overview = heal_overview(%{db: db_contract()})
    deps = heal_deps(overview, fn _ -> flunk("heal must not run") end, test_pid)

    assert {:error, message} =
             NixSwarm.CLI.run(
               [
                 "cluster",
                 "heal",
                 "db",
                 "--target",
                 "db@127.0.0.1",
                 "--node",
                 "db@127.0.0.2",
                 "--yes"
               ],
               fn _opts -> :ok end,
               deps
             )

    assert message =~ "must match placement owner"
    refute_received {:heal_opts, _}
  end

  test "cluster heal rejects an unconfigured --node value" do
    test_pid = self()
    overview = heal_overview(%{db: db_contract()})
    deps = heal_deps(overview, fn _ -> flunk("heal must not run") end, test_pid)

    assert {:error, message} =
             NixSwarm.CLI.run(
               [
                 "cluster",
                 "heal",
                 "db",
                 "--target",
                 "db@127.0.0.1",
                 "--node",
                 "db@198.51.100.9",
                 "--yes"
               ],
               fn _opts -> :ok end,
               deps
             )

    assert message =~ "unknown node \"db@198.51.100.9\""
    refute_received {:heal_opts, _}
  end

  test "cluster heal failures are reported with a useful message" do
    test_pid = self()
    overview = heal_overview(%{db: db_contract()})

    deps =
      heal_deps(overview, fn _ -> {:error, {:restore_failed, "/var/lib/db", :boom}} end, test_pid)

    assert {:error, message} =
             NixSwarm.CLI.run(
               ["cluster", "heal", "db", "--target", "db@127.0.0.1", "--yes"],
               fn _opts -> :ok end,
               deps
             )

    assert message =~ "cluster heal failed for db"
    assert message =~ ":boom"
  end
end
