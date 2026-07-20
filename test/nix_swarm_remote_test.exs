defmodule NixSwarmRemoteTest do
  use ExUnit.Case, async: true

  test "remote options derive an SSH host and reject operator cookies" do
    assert_raise NixSwarm.Remote.Error, ~r/missing required --target/, fn ->
      NixSwarm.Remote.options!([])
    end

    remote = NixSwarm.Remote.options!(target: "nix-swarm@node-a.example")
    assert remote.ssh_host == "node-a.example"

    overridden =
      NixSwarm.Remote.options!(
        target: "nix-swarm@node-a.example",
        ssh_host: "operator@10.0.0.10"
      )

    assert overridden.ssh_host == "operator@10.0.0.10"

    assert_raise NixSwarm.Remote.Error, ~r/cookie options were removed/, fn ->
      NixSwarm.Remote.options!(target: "nix-swarm@node-a.example", cookie: "secret")
    end

    assert_raise NixSwarm.Remote.Error, ~r/unsupported characters/, fn ->
      NixSwarm.Remote.options!(target: "nix-swarm@node-a.example\nowned")
    end
  end

  test "RPC accepts only the fixed read-only query surface" do
    remote = %{target: "nix-swarm@node", ssh_host: "node"}

    query_fun = fn ^remote, request -> {:ok, request} end

    assert NixSwarm.Remote.rpc!(
             remote,
             NixSwarm.API,
             :cluster_overview,
             [],
             query_fun
           ) == :cluster_overview

    assert NixSwarm.Remote.rpc!(remote, NixSwarm.API, :logs, ["api", 25], query_fun) ==
             {:logs, "api", 25}

    assert_raise NixSwarm.Remote.Error, ~r/not read-only or allowlisted/, fn ->
      NixSwarm.Remote.rpc!(remote, :erlang, :halt, [], query_fun)
    end

    refute NixSwarm.Remote.function_exported?(remote, NixSwarm.API, :reconcile_cluster, 0)
    assert NixSwarm.Remote.function_exported?(remote, NixSwarm.API, :cluster_logs, 2)
  end

  test "doctor reports restricted-query success and failure" do
    remote =
      NixSwarm.Remote.options!(
        target: "nix-swarm@node-a.example",
        ssh_host: "operator@node-a.example"
      )

    healthy =
      NixSwarm.Remote.diagnose_connection(remote,
        query_fun: fn _remote, :cluster_members ->
          {:ok, %{live_nodes: [:"nix-swarm@node-a.example"]}}
        end
      )

    assert NixSwarm.Remote.connected?(healthy)
    assert length(NixSwarm.Remote.doctor_context_rows(healthy)) == 3
    assert Enum.all?(NixSwarm.Remote.diagnostic_checks(healthy), &(&1.status == :ok))
    assert NixSwarm.Remote.format_doctor_report(healthy) =~ "restricted Nix-Swarm query API"

    failed =
      NixSwarm.Remote.diagnose_connection(remote,
        query_fun: fn _remote, :cluster_members -> {:error, :permission_denied} end
      )

    refute NixSwarm.Remote.connected?(failed)
    assert NixSwarm.Remote.format_connection_error(failed) =~ "unable to query"
    assert NixSwarm.Remote.format_doctor_report(failed) =~ "Issues were detected"
  end
end
