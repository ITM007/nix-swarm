defmodule NixSwarmDeployApplyPreflightTest do
  use ExUnit.Case, async: false

  alias NixSwarm.Deploy

  @host "root@node-a"

  defp manifest do
    %{
      "schemaVersion" => 1,
      "nodes" => %{
        "nix-swarm@node-a" => %{
          "availability" => "active",
          "deployHost" => @host,
          "nixosConfiguration" => "node-a"
        }
      }
    }
  end

  defp base_opts(runner) do
    source = Path.expand("..", __DIR__)

    [
      source: source,
      deployment_manifest: manifest(),
      health_check: false,
      runner: runner
    ]
  end

  # Records every executed command and returns success so tests stay offline.
  defp recording_runner(parent) do
    fn executable, args, _env, _timeout ->
      send(parent, {:run, executable, Enum.join(args, " ")})
      ""
    end
  end

  defp probe_map(overrides \\ %{}) do
    Map.merge(
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
      },
      overrides
    )
  end

  defp new_host_probes do
    probe_map(%{
      service: %{ok: true, state: :missing},
      query: %{ok: true, state: :missing},
      credential: %{ok: true, state: :missing}
    })
  end

  defp fixture_cookie do
    path =
      Path.join(System.tmp_dir!(), "nix-swarm-apply-#{System.unique_integer([:positive])}.cookie")

    File.write!(path, "apply-test-cookie-abcdefghijklmnopqrstuvwxyz012345\n")
    path
  end

  test "blocked preflight aborts before any command executes" do
    parent = self()
    runner = recording_runner(parent)

    blocked_probes = fn _target, _timeout -> probe_map(%{ssh: %{ok: false}}) end

    error =
      assert_raise RuntimeError, ~r/preflight blocked/, fn ->
        Deploy.run(
          Keyword.merge(base_opts(runner),
            probe_fun: blocked_probes,
            command_fun: fn _executable, _args -> raise "credentials must not run" end
          )
        )
      end

    assert error.message =~ @host
    refute_receive {:run, _executable, _args}, 50
  end

  test "mismatched credentials abort before any command executes" do
    parent = self()
    runner = recording_runner(parent)

    mismatched_probes = fn _target, _timeout ->
      probe_map(%{credential: %{ok: true, state: :mismatched}})
    end

    assert_raise RuntimeError, ~r/preflight blocked/, fn ->
      Deploy.run(
        Keyword.merge(base_opts(runner),
          probe_fun: mismatched_probes,
          command_fun: fn _executable, _args -> raise "credentials must not run" end
        )
      )
    end

    refute_receive {:run, _executable, _args}, 50
  end

  test "apply enrolls a missing credential exactly once before activating a new host" do
    parent = self()
    runner = recording_runner(parent)
    secret = fixture_cookie()

    credential_fun = fn executable, args ->
      send(parent, {:credential_command, executable, Enum.join(args, " ")})

      if Enum.join(args, " ") =~ "sha256sum" do
        {"__NIX_SWARM_MISSING__", 0}
      else
        {"", 0}
      end
    end

    plan =
      Deploy.run(
        Keyword.merge(base_opts(runner),
          probe_fun: fn _target, _timeout -> new_host_probes() end,
          command_fun: credential_fun,
          secret_file: secret
        )
      )

    all_commands = collect(parent)

    scp_count =
      all_commands
      |> Enum.count(fn
        {:credential_command, "scp", _args} -> true
        _ -> false
      end)

    assert scp_count == 1

    activate_count =
      all_commands
      |> Enum.count(fn
        {:run, "nixos-rebuild", args} -> args =~ "switch"
        _ -> false
      end)

    assert activate_count == 1

    assert [%{host: @host, classification: :new_nixos_host}] = plan.preflight
  end

  test "apply to an in-sync cluster performs no credential traffic" do
    parent = self()
    runner = recording_runner(parent)

    plan =
      Deploy.run(
        Keyword.merge(base_opts(runner),
          probe_fun: fn _target, _timeout -> probe_map() end,
          command_fun: fn _executable, _args -> raise "credentials must not run" end
        )
      )

    assert [%{host: @host, classification: :existing_in_sync}] = plan.preflight

    rebuilds = for {:run, "nixos-rebuild", args} <- collect(parent), args =~ "switch", do: 1
    assert length(rebuilds) == 1
    assert plan.results |> length() == 1
  end

  defp collect(_parent) do
    wait = fn ->
      receive do
        {:run, executable, args} -> {:run, executable, args}
        {:credential_command, executable, args} -> {:credential_command, executable, args}
      after
        0 -> nil
      end
    end

    Enum.reverse(Stream.repeatedly(fn -> wait.() end) |> Enum.take_while(&(&1 != nil)))
  end
end
