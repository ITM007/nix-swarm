defmodule NixSwarmMembershipTest do
  use ExUnit.Case, async: false

  @peer :"membership-peer@127.0.0.1"

  setup do
    previous = Application.get_env(:nix_swarm, :cluster_config)
    Application.stop(:nix_swarm)

    Application.put_env(:nix_swarm, :cluster_config, %{
      peers: [Node.self(), @peer],
      nodes: %{
        Node.self() => %{labels: ["apps"]},
        @peer => %{labels: ["apps"]}
      },
      services: [%{name: "api", replicas: 1, constraints: ["apps"]}],
      runtime: %{
        connect_interval_ms: 10_000,
        reconcile_interval_ms: 10_000,
        autoscale_interval_ms: 10_000,
        failure_grace_ms: 100,
        recovery_stabilization_ms: 100,
        executor: %{adapter: :fake, root: System.tmp_dir!()}
      }
    })

    {:ok, _apps} = Application.ensure_all_started(:nix_swarm)

    on_exit(fn ->
      Application.stop(:nix_swarm)

      if previous,
        do: Application.put_env(:nix_swarm, :cluster_config, previous),
        else: Application.delete_env(:nix_swarm, :cluster_config)

      {:ok, _apps} = Application.ensure_all_started(:nix_swarm)
    end)

    :ok
  end

  test "failure grace and recovery stabilization gate placement" do
    assert NixSwarm.Cluster.membership()[@peer].status == :down

    send(NixSwarm.Cluster, {:nodeup, @peer})
    assert eventually(fn -> NixSwarm.Cluster.membership()[@peer].status == :recovering end)
    refute @peer in NixSwarm.Cluster.placement_nodes()

    assert eventually(fn -> NixSwarm.Cluster.membership()[@peer].status == :up end)
    assert @peer in NixSwarm.Cluster.placement_nodes()

    send(NixSwarm.Cluster, {:nodedown, @peer})
    assert eventually(fn -> NixSwarm.Cluster.membership()[@peer].status == :suspect end)
    assert @peer in NixSwarm.Cluster.placement_nodes()

    assert eventually(fn -> NixSwarm.Cluster.membership()[@peer].status == :down end)
    refute @peer in NixSwarm.Cluster.placement_nodes()
  end

  test "autoscaler samples owned units without calling its own GenServer" do
    pid = Process.whereis(NixSwarm.Autoscaler)
    send(pid, :tick)
    Process.sleep(50)

    assert Process.alive?(pid)
    assert is_map(NixSwarm.Autoscaler.snapshot())
  end

  defp eventually(fun, attempts \\ 30)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
