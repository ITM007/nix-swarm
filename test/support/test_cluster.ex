defmodule Swarm.TestCluster do
  @moduledoc false

  def start_three_node_cluster(root) do
    File.rm_rf!(root)
    File.mkdir_p!(root)

    nodes = [:"node-a@127.0.0.1", :"node-b@127.0.0.1", :"node-c@127.0.0.1"]

    config = %{
      peers: nodes,
      nodes: %{
        :"node-a@127.0.0.1" => %{labels: ["ssd", "edge"]},
        :"node-b@127.0.0.1" => %{labels: ["ssd"]},
        :"node-c@127.0.0.1" => %{labels: ["ssd", "edge"]}
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
        executor: %{adapter: :fake, root: root},
        generation: "integration-test"
      }
    }

    peers =
      Enum.map(nodes, fn node_name ->
        {:ok, peer, node} =
          :peer.start_link(%{name: node_name, longnames: true, connection: :standard_io})

        :ok = :peer.call(peer, :application, :set_env, [:swarm, :cluster_config, config])

        Enum.each(:code.get_path(), fn path ->
          :peer.call(peer, :code, :add_patha, [path])
        end)

        {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:swarm])
        :ok = :peer.call(peer, Swarm.Cluster, :connect_now, [])
        {peer, node}
      end)

    wait_until(fn ->
      Enum.all?(nodes, fn node ->
        status = :rpc.call(node, Swarm.API, :cluster_members, [])
        Enum.sort(status.live_nodes) == nodes
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

  def unit_state(root, node_name, unit) do
    path = Path.join([root, sanitize(node_name), "#{unit}.state"])

    case File.read(path) do
      {:ok, content} -> String.trim(content)
      {:error, :enoent} -> "stopped"
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

  defp sanitize(node) do
    node
    |> Atom.to_string()
    |> String.replace(~r/[^a-zA-Z0-9_.-]/, "_")
  end
end
