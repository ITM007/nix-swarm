System.cmd("epmd", ["-daemon"])

case :net_kernel.start([:"verify-controller@127.0.0.1", :longnames]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

root = Path.join(System.tmp_dir!(), "swarm-verify-#{System.unique_integer([:positive])}")
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
    %{name: "gitea", replicas: 2, unit_template: "gitea@%{slot}.service", constraints: ["ssd"]},
    %{name: "proxy", replicas: 1, unit_template: "proxy@%{slot}.service", constraints: ["edge"]}
  ],
  runtime: %{
    connect_interval_ms: 100,
    reconcile_interval_ms: 100,
    executor: %{adapter: :fake, root: root},
    generation: "verify-script"
  }
}

wait_until = fn wait_until, fun, deadline ->
  cond do
    fun.() ->
      :ok

    System.monotonic_time(:millisecond) >= deadline ->
      raise "verification timed out"

    true ->
      Process.sleep(100)
      wait_until.(wait_until, fun, deadline)
  end
end

sanitize = fn node ->
  node
  |> Atom.to_string()
  |> String.replace(~r/[^a-zA-Z0-9_.-]/, "_")
end

unit_state = fn node, unit ->
  path = Path.join([root, sanitize.(node), "#{unit}.state"])

  case File.read(path) do
    {:ok, content} -> String.trim(content)
    {:error, :enoent} -> "stopped"
  end
end

converged? = fn live_nodes, placements ->
  Enum.all?(placements, fn {_service, slots} ->
    Enum.all?(slots, fn slot ->
      Enum.all?(live_nodes, fn node ->
        actual = unit_state.(node, slot.unit)
        expected = if node == slot.owner, do: "running", else: "stopped"
        actual == expected
      end)
    end)
  end)
end

start_peer = fn node_name ->
  {:ok, peer, node} = :peer.start_link(%{name: node_name, longnames: true, connection: :standard_io})
  :ok = :peer.call(peer, :application, :set_env, [:swarm, :cluster_config, config])

  Enum.each(:code.get_path(), fn path ->
    :peer.call(peer, :code, :add_patha, [path])
  end)

  {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:swarm])
  :ok = :peer.call(peer, Swarm.Cluster, :connect_now, [])
  {peer, node}
end

peers =
  Enum.map(nodes, fn node_name ->
    start_peer.(node_name)
  end)

wait_until.(wait_until, fn ->
  Enum.all?(nodes, fn node ->
    status = :rpc.call(node, Swarm.API, :cluster_members, [])
    Enum.sort(status.live_nodes) == nodes
  end)
end, System.monotonic_time(:millisecond) + 5_000)

wait_until.(wait_until, fn ->
  status = :rpc.call(hd(nodes), Swarm.API, :cluster_status, [])
  converged?.(nodes, status.placements)
end, System.monotonic_time(:millisecond) + 5_000)

IO.puts("=== initial cluster status ===")
Swarm.CLI.main([
  "--target",
  Atom.to_string(hd(nodes)),
  "--cookie",
  Atom.to_string(Node.get_cookie()),
  "status"
])

restart_results = :rpc.call(Enum.at(nodes, 1), Swarm.API, :restart_service, ["gitea"])

if length(restart_results) != 2 do
  raise "expected restart across two gitea owners, got #{inspect(restart_results)}"
end

logs = :rpc.call(Enum.at(nodes, 2), Swarm.API, :logs, ["gitea", 50])

unless Enum.any?(logs, fn {_node, entries} ->
         Enum.any?(entries, &String.contains?(&1.logs, "restart"))
       end) do
  raise "expected gitea restart to appear in logs"
end

{peer_a, node_a} = hd(peers)
:ok = :peer.stop(peer_a)

survivors = List.delete(nodes, node_a)

wait_until.(wait_until, fn ->
  status = :rpc.call(hd(survivors), Swarm.API, :cluster_status, [])
  Enum.sort(status.live_nodes) == Enum.sort(survivors)
end, System.monotonic_time(:millisecond) + 5_000)

wait_until.(wait_until, fn ->
  status = :rpc.call(hd(survivors), Swarm.API, :cluster_status, [])
  converged?.(survivors, status.placements)
end, System.monotonic_time(:millisecond) + 5_000)

IO.puts("")
IO.puts("=== status after node failure ===")
Swarm.CLI.main([
  "--target",
  Atom.to_string(hd(survivors)),
  "--cookie",
  Atom.to_string(Node.get_cookie()),
  "status"
])

IO.puts("")
IO.puts("three-node verification passed")

Enum.each(tl(peers), fn {peer, _node} ->
  :peer.stop(peer)
end)

File.rm_rf!(root)
