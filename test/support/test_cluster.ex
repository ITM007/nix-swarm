defmodule NixSwarm.TestCluster do
  @moduledoc false

  def start_three_node_cluster(root) do
    File.rm_rf!(root)
    File.mkdir_p!(root)

    nodes = [:"node-a@127.0.0.1", :"node-b@127.0.0.1", :"node-c@127.0.0.1"]

    config = %{
      peers: nodes,
      nodes: %{
        :"node-a@127.0.0.1" => %{labels: ["ssd", "edge"], deploy_host: "root@node-a"},
        :"node-b@127.0.0.1" => %{labels: ["ssd"], deploy_host: "root@node-b"},
        :"node-c@127.0.0.1" => %{labels: ["ssd", "edge"], deploy_host: "root@node-c"}
      },
      services: [
        %{
          name: "gitea",
          replicas: 2,
          unit_template: "gitea@%{slot}.service",
          constraints: ["ssd"]
        },
        %{
          name: "proxy",
          replicas: 1,
          unit_template: "proxy@%{slot}.service",
          constraints: ["edge"]
        }
      ],
      runtime: %{
        connect_interval_ms: 100,
        reconcile_interval_ms: 100,
        autoscale_interval_ms: 1_000,
        failure_grace_ms: 200,
        recovery_stabilization_ms: 200,
        executor: %{adapter: :fake, root: root},
        generation: "integration-test"
      }
    }

    peers =
      Enum.map(nodes, fn node_name ->
        {:ok, peer, node} =
          :peer.start_link(%{name: node_name, longnames: true, connection: :standard_io})

        :ok = :peer.call(peer, :application, :set_env, [:nix_swarm, :cluster_config, config])

        Enum.each(:code.get_path(), fn path ->
          :peer.call(peer, :code, :add_patha, [path])
        end)

        {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:nix_swarm])
        :ok = :peer.call(peer, NixSwarm.Cluster, :connect_now, [])
        {peer, node}
      end)

    wait_until(fn ->
      Enum.all?(nodes, fn node ->
        status = :rpc.call(node, NixSwarm.API, :cluster_members, [])
        Enum.sort(status.live_nodes) == nodes and Enum.sort(status.placement_nodes) == nodes
      end)
    end)

    %{config: config, peers: peers, nodes: nodes, root: root}
  end

  def stop_cluster(cluster) do
    Enum.each(cluster.peers, fn {peer, _node} ->
      try do
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end
    end)
  end

  def peer_for(cluster, node_name) do
    cluster.peers
    |> Enum.find_value(fn {peer, node} ->
      if node == node_name, do: peer
    end)
  end

  def remote_for(cluster, target_node) do
    query_fun = fn _remote, request ->
      result =
        case request do
          :cluster_members ->
            :rpc.call(target_node, NixSwarm.API, :cluster_members, [])

          :cluster_overview ->
            :rpc.call(target_node, NixSwarm.API, :cluster_overview, [])

          {:operator_snapshot, service, node, lines} ->
            selected_node =
              case node do
                value when is_atom(value) ->
                  value

                value when is_binary(value) ->
                  Enum.find(cluster.nodes, &(Atom.to_string(&1) == value))

                _value ->
                  nil
              end

            :rpc.call(target_node, NixSwarm.API, :operator_snapshot, [
              service,
              selected_node,
              lines
            ])

          {:logs, service, lines} ->
            :rpc.call(target_node, NixSwarm.API, :logs, [service, lines])

          {:node_service_logs, node, lines} ->
            :rpc.call(target_node, NixSwarm.API, :node_service_logs, [node, lines])

          {:cluster_logs, node, lines} ->
            :rpc.call(target_node, NixSwarm.API, :cluster_logs, [node, lines])
        end

      case result do
        {:badrpc, reason} -> {:error, reason}
        value -> {:ok, value}
      end
    end

    NixSwarm.Remote.options!(target: Atom.to_string(target_node), query_fun: query_fun)
  end

  def unit_state(root, node_name, unit) do
    path =
      Path.join([root, NixSwarm.Executor.Fake.sanitize_node_name(node_name), "#{unit}.state"])

    case File.read(path) do
      {:ok, content} -> String.trim(content)
      {:error, :enoent} -> "stopped"
    end
  end

  def machine_actions(root, node_name) do
    path = Path.join([root, NixSwarm.Executor.Fake.sanitize_node_name(node_name), "machine.log"])

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)

      {:error, :enoent} ->
        []
    end
  end

  def wait_until(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "condition not met before timeout"
      end

      Process.sleep(100)
      do_wait_until(fun, deadline)
    end
  end
end
