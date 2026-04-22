defmodule Swarm.CLI do
  @moduledoc false

  defmodule Error do
    defexception [:message]
  end

  def main(argv) do
    case run(argv) do
      :ok ->
        :ok

      {:error, message} ->
        print_error(message)
        System.halt(1)
    end
  end

  def run(argv) do
    {opts, args, _invalid} =
      OptionParser.parse(argv,
        strict: [
          target: :string,
          cookie: :string,
          name: :string,
          lines: :integer,
          output: :string,
          host: :string,
          hosts: :string,
          source: :string,
          node_name: :string,
          cookie_file: :string,
          cluster_module: :string,
          module_ref: :string,
          package_ref: :string,
          remote_path: :string,
          nixos_dir: :string,
          flake: :string,
          build_host: :string,
          dry_run: :boolean,
          deploy: :boolean
        ]
      )

    case args do
      ["status"] ->
        with_remote(opts, fn target ->
          print_status(rpc!(target, Swarm.API, :cluster_status, []))
        end)

      ["cluster", "members"] ->
        with_remote(opts, fn target ->
          print_members(rpc!(target, Swarm.API, :cluster_members, []))
        end)

      ["cluster", "map"] ->
        with_remote(opts, fn target ->
          print_cluster_map(rpc!(target, Swarm.API, :cluster_overview, []))
        end)

      ["reconcile"] ->
        with_remote(opts, fn target ->
          IO.inspect(rpc!(target, Swarm.API, :reconcile_cluster, []), pretty: true)
        end)

      ["restart", service_name] ->
        with_remote(opts, fn target ->
          IO.inspect(rpc!(target, Swarm.API, :restart_service, [service_name]), pretty: true)
        end)

      ["logs", service_name] ->
        lines = Keyword.get(opts, :lines, 50)

        with_remote(opts, fn target ->
          print_logs(rpc!(target, Swarm.API, :logs, [service_name, lines]))
        end)

      ["add-machine"] ->
        print_bootstrap_result(Swarm.Bootstrap.run(opts))

      ["apply"] ->
        print_apply_result(Swarm.Deploy.run(opts))

      _ ->
        IO.puts("""
        usage:
          swarm --target node-a@127.0.0.1 --cookie swarm status
          swarm --target node-a@127.0.0.1 --cookie swarm cluster members
          swarm --target node-a@127.0.0.1 --cookie swarm cluster map
          swarm --target node-a@127.0.0.1 --cookie swarm restart SERVICE
          swarm --target node-a@127.0.0.1 --cookie swarm logs SERVICE --lines 100
          swarm --target node-a@127.0.0.1 --cookie swarm reconcile
          swarm add-machine --output ./machines/node-d.nix --node-name node-d@10.0.0.14 --cookie-file ../secrets/swarm.cookie
          swarm add-machine --output ./machines/node-d.nix --node-name node-d@10.0.0.14 --cookie-file ../secrets/swarm.cookie --hosts root@10.0.0.14 --deploy
          swarm apply --dry-run --hosts nixos-2,nixos-3
          swarm apply --hosts nixos-2,nixos-3
          swarm apply --hosts root@10.0.0.14,root@10.0.0.15 --source . --remote-path /etc/nixos/nix-swarm
        """)

        :ok
    end
  rescue
    error in [Error, ArgumentError, RuntimeError] ->
      {:error, Exception.message(error)}
  end

  defp with_remote(opts, callback) do
    target = Keyword.fetch!(opts, :target)
    cookie = Keyword.get(opts, :cookie, "swarm")
    cli_name = Keyword.get(opts, :name)
    target_node = ensure_connection(target, cookie, cli_name)
    callback.(target_node)
    :ok
  end

  defp ensure_connection(target, cookie, cli_name) do
    target_node = String.to_atom(target)
    %{name: cli_node_name, mode: node_mode} = cli_node_identity(target, cli_name)

    unless Node.alive?() do
      System.cmd("epmd", ["-daemon"])
      ensure_net_kernel_started(cli_node_name, node_mode)
    else
      ensure_node_mode!(node_mode)
    end

    Node.set_cookie(String.to_atom(cookie))

    case Node.connect(target_node) do
      true -> target_node
      false -> fail(connection_error_message(target))
      :ignored -> target_node
    end
  end

  @doc false
  def cli_node_identity(target, cli_name \\ nil, host_resolver \\ &local_host_for_target/1) do
    {node_mode, target_host} = target_mode_and_host(target)

    name =
      case {cli_name, node_mode} do
        {nil, :longnames} ->
          host = host_resolver.(target_host)
          "swarmctl-#{System.unique_integer([:positive])}@#{host}"

        {nil, :shortnames} ->
          "swarmctl-#{System.unique_integer([:positive])}"

        {provided_name, :longnames} ->
          if String.contains?(provided_name, "@") do
            provided_name
          else
            fail("--name must include @HOST when connecting to a longname target")
          end

        {provided_name, :shortnames} ->
          provided_name
      end

    %{name: String.to_atom(name), mode: node_mode}
  end

  defp ensure_net_kernel_started(cli_node_name, node_mode) do
    case :net_kernel.start([cli_node_name, node_mode]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        fail("failed to start CLI node #{cli_node_name}: #{inspect(reason)}")
    end
  end

  defp ensure_node_mode!(expected_mode) do
    current_mode = target_mode_and_host(Atom.to_string(Node.self())) |> elem(0)

    if current_mode != expected_mode do
      fail(
        "CLI node #{Node.self()} is already running with #{current_mode}, but the target requires #{expected_mode}"
      )
    end
  end

  defp target_mode_and_host(target) do
    case String.split(target, "@", parts: 2) do
      [_name, host] -> {node_mode_for_host(host), host}
      [_name] -> {:shortnames, nil}
    end
  end

  defp node_mode_for_host(host) when is_binary(host) do
    if String.contains?(host, ".") or String.contains?(host, ":") do
      :longnames
    else
      :shortnames
    end
  end

  defp local_host_for_target(target_host) do
    with {:ok, target_address} <- resolve_host(target_host),
         {:ok, local_host} <- local_host_for_address(target_address) do
      local_host
    else
      _ -> fallback_local_host()
    end
  end

  defp resolve_host(nil), do: {:error, :missing_host}

  defp resolve_host(host) do
    charlist = String.to_charlist(host)

    case :inet.getaddr(charlist, :inet) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :inet.getaddr(charlist, :inet6)
    end
  end

  defp local_host_for_address(target_address) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        try do
          with :ok <- :gen_udp.connect(socket, target_address, 4369),
               {:ok, {local_address, _port}} <- :inet.sockname(socket) do
            {:ok, local_address |> :inet.ntoa() |> to_string()}
          end
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fallback_local_host do
    case :inet.gethostname() do
      {:ok, hostname} -> List.to_string(hostname)
      {:error, _reason} -> "localhost"
    end
  end

  defp connection_error_message(target) do
    """
    unable to connect to #{target}

    check:
      - the target node is running and reachable
      - the cookie matches on both nodes
      - the CLI node host is reachable from the target

    hint: pass --name swarmctl@YOUR_IP if auto-detection picks the wrong local host
    """
    |> String.trim()
  end

  defp rpc!(node, module, function, args) do
    case :rpc.call(node, module, function, args, 5_000) do
      {:badrpc, reason} ->
        fail(
          "remote call #{inspect(module)}.#{function}/#{length(args)} failed on #{node}: #{inspect(reason)}"
        )

      result ->
        result
    end
  end

  defp fail(message), do: raise(Error, message: message)

  defp print_error(message), do: IO.puts(:stderr, "error: #{message}")

  defp print_members(%{
         queried_node: queried_node,
         configured_nodes: configured_nodes,
         live_nodes: live_nodes
       }) do
    IO.puts("cluster members")
    IO.puts("===============")
    IO.puts("queried node: #{queried_node}")
    IO.puts("configured: #{Enum.map_join(configured_nodes, ", ", &Atom.to_string/1)}")
    IO.puts("live:       #{Enum.map_join(live_nodes, ", ", &Atom.to_string/1)}")
  end

  defp print_status(%{
         queried_node: queried_node,
         live_nodes: live_nodes,
         placements: placements,
         nodes: nodes
       }) do
    IO.puts("queried node: #{queried_node}")
    IO.puts("live nodes:   #{Enum.map_join(live_nodes, ", ", &Atom.to_string/1)}")
    IO.puts("")
    IO.puts("placements:")

    Enum.each(placements, fn {service, slots} ->
      IO.puts("  #{service}")

      Enum.each(slots, fn slot ->
        owner = if slot.owner, do: Atom.to_string(slot.owner), else: "unplaced"
        IO.puts("    slot #{slot.slot} -> #{owner} (#{slot.unit})")
      end)
    end)

    IO.puts("")
    IO.puts("node status:")

    Enum.each(nodes, fn {node, status} ->
      IO.puts("  #{node}")

      case status do
        %{services: services} ->
          Enum.each(services, fn service ->
            owned =
              service.local_owned_slots
              |> Enum.map_join(", ", &Integer.to_string/1)

            owned_display = if owned == "", do: "-", else: owned
            IO.puts("    #{service.name} owned slots: #{owned_display}")

            Enum.each(service.units, fn unit ->
              owner = if unit.owner, do: Atom.to_string(unit.owner), else: "unplaced"
              IO.puts("      #{unit.unit} owner=#{owner} status=#{unit.status}")
            end)
          end)

        other ->
          IO.puts("    #{inspect(other)}")
      end
    end)
  end

  defp print_logs(logs) do
    Enum.each(logs, fn {node, entries} ->
      IO.puts("node #{node}")

      Enum.each(entries, fn entry ->
        IO.puts("  #{entry.unit}")

        if entry.logs == "" do
          IO.puts("    <no logs>")
        else
          entry.logs
          |> String.split("\n", trim: true)
          |> Enum.each(&IO.puts("    " <> &1))
        end
      end)
    end)
  end

  defp print_cluster_map(%{members: members, status: status}) do
    configured_nodes = members.configured_nodes
    live_nodes = MapSet.new(members.live_nodes)

    owned_by_node =
      status.placements
      |> Enum.flat_map(fn {service, slots} ->
        Enum.map(slots, fn slot ->
          Map.put(slot, :service, service)
        end)
      end)
      |> Enum.group_by(& &1.owner)

    IO.puts("cluster map")
    IO.puts("===========")
    IO.puts("nodes")

    Enum.with_index(configured_nodes)
    |> Enum.each(fn {node, index} ->
      connector = if index == length(configured_nodes) - 1, do: "└─", else: "├─"
      state = if MapSet.member?(live_nodes, node), do: "up", else: "down"
      IO.puts("#{connector} #{node} [#{state}]")

      node_slots = Map.get(owned_by_node, node, [])

      case node_slots do
        [] ->
          continuation = if index == length(configured_nodes) - 1, do: "   ", else: "│  "
          IO.puts("#{continuation}└─ idle")

        slots ->
          Enum.with_index(slots)
          |> Enum.each(fn {slot, slot_index} ->
            continuation = if index == length(configured_nodes) - 1, do: "   ", else: "│  "
            slot_connector = if slot_index == length(slots) - 1, do: "└─", else: "├─"

            IO.puts(
              "#{continuation}#{slot_connector} #{slot.service} slot #{slot.slot} (#{slot.unit})"
            )
          end)
      end
    end)

    IO.puts("")
    IO.puts("services")

    status.placements
    |> Enum.with_index()
    |> Enum.each(fn {{service, slots}, index} ->
      connector = if index == map_size(status.placements) - 1, do: "└─", else: "├─"

      summary =
        slots
        |> Enum.map(fn slot ->
          owner = if slot.owner, do: Atom.to_string(slot.owner), else: "unplaced"
          "slot #{slot.slot} -> #{owner}"
        end)
        |> Enum.join(", ")

      IO.puts("#{connector} #{service}: #{summary}")
    end)
  end

  defp print_bootstrap_result(%{output: output, deployed: false}) do
    IO.puts("wrote machine bootstrap file to #{output}")

    IO.puts(
      "next step: update cluster/cluster.nix, add any service files under cluster/services/, then run swarm apply or nixos-rebuild"
    )
  end

  defp print_bootstrap_result(%{output: output, deployed: true, deploy_output: deploy_output}) do
    IO.puts("wrote machine bootstrap file to #{output}")
    print_apply_result(deploy_output)
  end

  defp print_apply_result(%{dry_run: true, validation: validation, results: results}) do
    IO.puts("dry run complete: configuration validated")
    IO.puts("validated machine files:")

    Enum.each(validation.machine_files, fn machine_file ->
      IO.puts("  #{Path.relative_to_cwd(machine_file)}")
    end)

    IO.puts("")
    IO.puts("planned commands:")

    Enum.each(results, fn %{
                            host: host,
                            sync_command: sync_command,
                            rebuild_command: rebuild_command
                          } ->
      IO.puts("  #{host}")
      IO.puts("    sync:    #{sync_command}")
      IO.puts("    rebuild: #{rebuild_command}")
    end)
  end

  defp print_apply_result(%{results: results}) do
    IO.puts("configuration validated")

    Enum.each(results, fn %{host: host} ->
      IO.puts("applied cluster config to #{host}")
    end)
  end
end
