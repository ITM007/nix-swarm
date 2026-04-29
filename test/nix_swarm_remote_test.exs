defmodule NixSwarmRemoteTest do
  use ExUnit.Case, async: true

  test "rpc falls back to legacy Swarm.API for cluster overview" do
    node = :"swarm@example-node-a.local"

    rpc_fun = fn
      ^node, NixSwarm.API, :cluster_overview, [], 5_000 ->
        {:badrpc, {:EXIT, {:undef, [{NixSwarm.API, :cluster_overview, [], []}]}}}

      ^node, Swarm.API, :cluster_overview, [], 5_000 ->
        %{
          members: %{live_nodes: [node]},
          status: %{queried_node: node, live_nodes: [node], placements: %{}, nodes: []}
        }
    end

    overview = NixSwarm.Remote.rpc!(node, NixSwarm.API, :cluster_overview, [], rpc_fun)

    assert overview.members.live_nodes == [node]
    assert overview.status.queried_node == node
  end

  test "function_exported? checks the legacy Swarm.API fallback" do
    node = :"swarm@example-node-a.local"

    rpc_fun = fn
      ^node, :erlang, :function_exported, [NixSwarm.API, :cluster_logs, 2], 5_000 -> false
      ^node, :erlang, :function_exported, [Swarm.API, :cluster_logs, 2], 5_000 -> true
      ^node, :erlang, :function_exported, [NixSwarm.API, :local_cluster_logs, 1], 5_000 -> false
      ^node, :erlang, :function_exported, [Swarm.API, :local_cluster_logs, 1], 5_000 -> true
    end

    assert NixSwarm.Remote.function_exported?(node, NixSwarm.API, :cluster_logs, 2, rpc_fun)
    assert NixSwarm.Remote.function_exported?(node, NixSwarm.API, :local_cluster_logs, 1, rpc_fun)
  end
end
