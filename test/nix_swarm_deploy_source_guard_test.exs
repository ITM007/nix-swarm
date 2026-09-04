defmodule NixSwarmDeploySourceGuardTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias NixSwarm.Deploy

  @host "root@node-a"

  @manifest %{
    "schemaVersion" => 1,
    "nodes" => %{
      "nix-swarm@node-a" => %{
        "deployHost" => @host,
        "nixosConfiguration" => "node-a"
      }
    }
  }

  defp git_repo! do
    root =
      Path.join(
        System.tmp_dir!(),
        "nix-swarm-dirty-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: root, stderr_to_stdout: true)

    File.write!(
      Path.join(root, "flake.nix"),
      "{ description = \"test\"; outputs = { self }: { }; }\n"
    )

    File.write!(Path.join(root, "cluster.nix"), "# uncommitted change\n")

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp healthy_probes do
    %{
      ssh: %{ok: true},
      nixos: %{ok: true},
      privilege: %{ok: true},
      architecture: %{ok: true},
      disk: %{ok: true},
      credential: %{ok: true, state: :present},
      service: %{ok: true, state: :active},
      query: %{ok: true, state: :in_sync},
      protocol: %{ok: true, state: :compatible}
    }
  end

  defp base_opts(source) do
    [
      source: source,
      hosts: [@host],
      deployment_manifest: @manifest,
      health_check: false,
      runner: fn _exe, _args, _env, _timeout -> "" end,
      probe_fun: fn _target, _timeout -> healthy_probes() end
    ]
  end

  test "cluster apply refuses a dirty source tree unless --allow-dirty" do
    source = git_repo!()

    # The runner would raise if the refusal happened after any host mutation;
    # the refusal must precede plan execution entirely.
    message =
      assert_raise ArgumentError, fn ->
        Deploy.run(
          source: source,
          deployment_manifest: @manifest,
          runner: fn _exe, _args, _env, _timeout -> raise "runner must not be invoked" end
        )
      end

    assert message.message =~ "dirty"
    assert message.message =~ "--allow-dirty"
  end

  test "cluster apply proceeds with --allow-dirty on a dirty source tree" do
    source = git_repo!()

    plan = Deploy.run(Keyword.put(base_opts(source), :allow_dirty, true))
    assert plan.hosts == [@host]
    assert plan.dry_run == false
  end

  test "cluster plan warns (but does not refuse) on a dirty source tree" do
    source = git_repo!()

    log =
      capture_log(fn ->
        plan = Deploy.run(Keyword.put(base_opts(source), :dry_run, true))
        assert plan.hosts == [@host]
        assert plan.dry_run == true
      end)

    assert log =~ "dirty"
    assert log =~ "--allow-dirty"
  end

  test "apply is allowed on a clean repository" do
    source = git_repo!()
    {_, 0} = System.cmd("git", ["add", "."], cd: source, stderr_to_stdout: true)

    env = [
      {"GIT_AUTHOR_NAME", "test"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "test"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"}
    ]

    {_, 0} =
      System.cmd("git", ["commit", "-q", "-m", "baseline"],
        cd: source,
        env: env,
        stderr_to_stdout: true
      )

    plan = Deploy.run(base_opts(source))
    assert plan.hosts == [@host]
  end
end
