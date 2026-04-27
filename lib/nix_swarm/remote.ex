defmodule NixSwarm.Remote do
  @moduledoc false

  alias NixSwarm.NodeName

  @epmd_port 4369
  @default_distribution_port 4370
  @tcp_connect_timeout_ms 1_000

  defmodule Error do
    defexception [:message]
  end

  def with_connection(opts, callback) when is_list(opts) do
    target_node = connect!(opts)
    callback.(target_node)
    :ok
  end

  def options!(opts) when is_list(opts) do
    target =
      case Keyword.fetch(opts, :target) do
        {:ok, value} -> value
        :error -> fail("missing required --target for remote command")
      end

    {cookie, cookie_source} = remote_cookie(opts)

    %{
      target: target,
      cookie: cookie,
      cookie_source: cookie_source,
      cli_name: Keyword.get(opts, :cli_name) || Keyword.get(opts, :name)
    }
  end

  def connect!(opts) when is_list(opts), do: opts |> options!() |> connect!()

  def connect!(remote) when is_map(remote) do
    diagnostic = diagnose_connection(remote)

    if connected?(diagnostic) do
      diagnostic.target_node
    else
      fail(format_connection_error(diagnostic))
    end
  end

  def connected?(%{connect_result: result}), do: result in [true, :ignored]

  def diagnose_connection(remote), do: diagnose_connection(remote, [])

  def diagnose_connection(%{target: target, cookie: cookie, cli_name: cli_name} = remote, opts)
      when is_list(opts) do
    target_node = NodeName.to_node!(target, label: "target node")
    {node_mode, target_host} = target_mode_and_host(target)
    %{name: cli_node_name} = cli_node_identity(target, cli_name)
    skip_port_checks? = Keyword.get(opts, :skip_port_checks, false)

    ensure_cli_node(cli_node_name, node_mode)
    Node.set_cookie(NodeName.cookie_atom!(cookie))

    target_resolution = resolve_host_details(target_host)
    target_port_checks = target_port_checks(node_mode, target_resolution, skip_port_checks?)
    local_ip_candidates = local_ip_candidates()
    connect_result = ensure_connected(target_node)
    remote_probe = probe_remote(target_node, connect_result)

    Map.merge(remote, %{
      target_node: target_node,
      target_mode: node_mode,
      target_host: target_host,
      cli_node: Node.self(),
      target_resolution: target_resolution,
      target_port_checks: target_port_checks,
      local_ip_candidates: local_ip_candidates,
      connect_result: connect_result,
      remote_probe: remote_probe
    })
  end

  def cli_node_identity(target, cli_name \\ nil, host_resolver \\ &local_host_for_target/1) do
    {node_mode, target_host} = target_mode_and_host(target)

    name =
      case {cli_name, node_mode} do
        {nil, :longnames} ->
          host = host_resolver.(target_host)
          "nix-swarmctl-#{System.unique_integer([:positive])}@#{host}"

        {nil, :shortnames} ->
          "nix-swarmctl-#{System.unique_integer([:positive])}"

        {provided_name, :longnames} ->
          if String.contains?(provided_name, "@") do
            provided_name
          else
            fail("--name must include @HOST when connecting to a longname target")
          end

        {provided_name, :shortnames} ->
          provided_name
      end

    %{name: NodeName.to_node!(name, label: "CLI node name"), mode: node_mode}
  end

  def rpc!(node, module, function, args) do
    case :rpc.call(node, module, function, args, 5_000) do
      {:badrpc, reason} ->
        fail(
          "remote call #{inspect(module)}.#{function}/#{length(args)} failed on #{node}: #{inspect(reason)}"
        )

      result ->
        result
    end
  end

  def doctor_context_rows(diagnostic) do
    [
      ["target node", diagnostic.target],
      ["target host", diagnostic.target_host || "shortname target"],
      ["target mode", diagnostic.target_mode],
      [
        "local control node",
        "#{diagnostic.cli_node} (#{cli_node_source_label(diagnostic.cli_name)})"
      ],
      ["cookie source", cookie_source_label(diagnostic.cookie_source)],
      ["local IP candidates", format_list(diagnostic.local_ip_candidates)]
    ]
  end

  def diagnostic_checks(diagnostic) do
    [resolution_check(diagnostic)]
    |> Kernel.++(diagnostic.target_port_checks)
    |> Kernel.++([connectivity_check(diagnostic)])
    |> Kernel.++(remote_probe_checks(diagnostic))
  end

  def connection_solutions(diagnostic) do
    []
    |> maybe_add_solution(target_resolution_solution(diagnostic))
    |> maybe_add_solution(port_solution(diagnostic, @epmd_port))
    |> maybe_add_solution(port_solution(diagnostic, @default_distribution_port))
    |> maybe_add_solution(connection_failure_solution(diagnostic))
    |> maybe_add_solution(name_override_solution(diagnostic))
    |> maybe_add_solution(remote_api_solution(diagnostic))
    |> maybe_add_solution(success_solution(diagnostic))
    |> Enum.uniq()
  end

  def format_connection_error(diagnostic) do
    """
    unable to connect to #{diagnostic.target}

    connection context:
      target node: #{diagnostic.target}
      target host: #{diagnostic.target_host || "shortname target"}
      target mode: #{diagnostic.target_mode}
      local control node: #{diagnostic.cli_node} (#{cli_node_source_label(diagnostic.cli_name)})
      cookie source: #{cookie_source_label(diagnostic.cookie_source)}
      local IP candidates: #{format_list(diagnostic.local_ip_candidates)}

    checks:
    #{Enum.map_join(diagnostic_checks(diagnostic), "\n", &format_check_line/1)}

    likely fixes:
    #{Enum.map_join(connection_solutions(diagnostic), "\n", &"  - #{&1}")}

    next step:
      relaunch `nix-swarm --target #{diagnostic.target}` with the same cookie source after applying the fixes above
    """
    |> String.trim()
  end

  def format_doctor_report(diagnostic) do
    heading = "doctor for #{diagnostic.target}"

    """
    #{heading}
    #{String.duplicate("=", String.length(heading))}
    connection context:
      target node: #{diagnostic.target}
      target host: #{diagnostic.target_host || "shortname target"}
      target mode: #{diagnostic.target_mode}
      local control node: #{diagnostic.cli_node} (#{cli_node_source_label(diagnostic.cli_name)})
      cookie source: #{cookie_source_label(diagnostic.cookie_source)}
      local IP candidates: #{format_list(diagnostic.local_ip_candidates)}

    checks:
    #{Enum.map_join(diagnostic_checks(diagnostic), "\n", &format_check_line/1)}

    result:
      #{doctor_result(diagnostic)}

    fixes and next steps:
    #{Enum.map_join(connection_solutions(diagnostic), "\n", &"  - #{&1}")}
    """
    |> String.trim()
  end

  def doctor_result(%{connect_result: result, remote_probe: %{cluster_members: %{status: :ok}}})
      when result in [true, :ignored] do
    "The target is reachable and the Nix-Swarm API responded. This machine can control the cluster through #{result_label(result)}."
  end

  def doctor_result(%{connect_result: result}) when result in [true, :ignored] do
    "The Erlang connection worked, but the target did not answer the Nix-Swarm API cleanly."
  end

  def doctor_result(_diagnostic) do
    "Issues were detected. Fix the failed checks above, then relaunch the TUI."
  end

  defp remote_cookie(opts) do
    cond do
      Keyword.has_key?(opts, :cookie) ->
        {Keyword.fetch!(opts, :cookie), :provided}

      Keyword.has_key?(opts, :cookie_file) ->
        {read_cookie_file!(Keyword.fetch!(opts, :cookie_file)), :cookie_file}

      System.get_env("NIX_SWARM_COOKIE") not in [nil, ""] ->
        {System.get_env("NIX_SWARM_COOKIE"), :env}

      System.get_env("NIX_SWARM_COOKIE_FILE") not in [nil, ""] ->
        {read_cookie_file!(System.get_env("NIX_SWARM_COOKIE_FILE")), :env_file}

      true ->
        fail(
          "missing cookie for remote command; pass --cookie or --cookie-file, or set NIX_SWARM_COOKIE / NIX_SWARM_COOKIE_FILE"
        )
    end
  end

  defp read_cookie_file!(path) do
    case File.read(path) do
      {:ok, contents} ->
        cookie = String.trim(contents)

        if cookie == "" do
          fail("cookie file is empty: #{path}")
        else
          cookie
        end

      {:error, reason} ->
        fail("failed to read cookie file #{path}: #{:file.format_error(reason)}")
    end
  end

  defp ensure_cli_node(cli_node_name, node_mode) do
    unless Node.alive?() do
      System.cmd("epmd", ["-daemon"])
      ensure_net_kernel_started(cli_node_name, node_mode)
    else
      ensure_node_mode!(node_mode)
    end
  end

  defp ensure_net_kernel_started(cli_node_name, node_mode) do
    case :net_kernel.start([cli_node_name, node_mode]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        fail("failed to start local control node #{cli_node_name}: #{inspect(reason)}")
    end
  end

  defp ensure_node_mode!(expected_mode) do
    current_mode = target_mode_and_host(Atom.to_string(Node.self())) |> elem(0)

    if current_mode != expected_mode do
      fail(
        "local control node #{Node.self()} is already running with #{current_mode}, but the target requires #{expected_mode}"
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
          with :ok <- :gen_udp.connect(socket, target_address, @epmd_port),
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

  defp resolve_host_details(nil) do
    %{
      status: :info,
      host: nil,
      address: nil,
      detail: "shortname target; no remote host lookup was required"
    }
  end

  defp resolve_host_details(host) do
    case resolve_host(host) do
      {:ok, address} ->
        %{
          status: :ok,
          host: host,
          address: address,
          detail: address |> :inet.ntoa() |> to_string()
        }

      {:error, reason} ->
        %{
          status: :error,
          host: host,
          address: nil,
          detail: inspect(reason)
        }
    end
  end

  defp ensure_connected(target_node) do
    cond do
      target_node == Node.self() -> :ignored
      target_node in Node.list() -> :ignored
      true -> Node.connect(target_node)
    end
  end

  defp target_port_checks(_node_mode, _target_resolution, true), do: []
  defp target_port_checks(:shortnames, _target_resolution, false), do: []

  defp target_port_checks(_node_mode, %{status: :ok, address: address}, false) do
    [
      tcp_port_check(address, @epmd_port, "target epmd TCP port #{@epmd_port}"),
      tcp_port_check(
        address,
        @default_distribution_port,
        "target Nix-Swarm distribution TCP port #{@default_distribution_port}"
      )
    ]
  end

  defp target_port_checks(_node_mode, _target_resolution, false) do
    [
      %{
        label: "target epmd TCP port #{@epmd_port}",
        status: :info,
        detail: "skipped because the target host could not be resolved"
      },
      %{
        label: "target Nix-Swarm distribution TCP port #{@default_distribution_port}",
        status: :info,
        detail: "skipped because the target host could not be resolved"
      }
    ]
  end

  defp tcp_port_check(address, port, label) do
    case :gen_tcp.connect(address, port, [:binary, active: false], @tcp_connect_timeout_ms) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        %{label: label, status: :ok, detail: "reachable"}

      {:error, reason} ->
        %{label: label, status: :error, detail: inspect(reason)}
    end
  end

  defp probe_remote(_target_node, connect_result) when connect_result not in [true, :ignored] do
    %{
      remote_self: %{
        status: :info,
        detail: "skipped because the distributed Erlang connection failed"
      },
      cluster_members: %{
        status: :info,
        detail: "skipped because the distributed Erlang connection failed"
      }
    }
  end

  defp probe_remote(target_node, _connect_result) do
    %{
      remote_self: rpc_probe(target_node, Node, :self, []),
      cluster_members: rpc_probe(target_node, NixSwarm.API, :cluster_members, [])
    }
  end

  defp rpc_probe(node, module, function, args) do
    case :rpc.call(node, module, function, args, 5_000) do
      {:badrpc, reason} ->
        %{status: :error, detail: inspect(reason)}

      value ->
        %{status: :ok, value: value}
    end
  end

  defp local_ip_candidates do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        interfaces
        |> Enum.flat_map(fn {_name, options} ->
          options
          |> Keyword.get_values(:addr)
          |> Enum.map(&format_ip_address/1)
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&(&1 in ["127.0.0.1", "::1"]))
        |> Enum.uniq()
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp format_ip_address(address) when tuple_size(address) in [4, 8] do
    address |> :inet.ntoa() |> to_string()
  end

  defp format_ip_address(_address), do: nil

  defp resolution_check(%{target_resolution: %{status: :ok, host: host, detail: detail}}) do
    %{label: "target host #{host} resolves", status: :ok, detail: detail}
  end

  defp resolution_check(%{target_resolution: %{status: :error, host: host, detail: detail}}) do
    %{label: "target host #{host} resolves", status: :error, detail: detail}
  end

  defp resolution_check(%{target_resolution: %{detail: detail}}) do
    %{label: "target host resolution", status: :info, detail: detail}
  end

  defp connectivity_check(%{target: target, connect_result: true}) do
    %{label: "distributed Erlang connection to #{target}", status: :ok, detail: "connected"}
  end

  defp connectivity_check(%{target: target, connect_result: :ignored}) do
    %{
      label: "distributed Erlang connection to #{target}",
      status: :ok,
      detail: "already connected"
    }
  end

  defp connectivity_check(%{target: target, connect_result: false}) do
    %{
      label: "distributed Erlang connection to #{target}",
      status: :error,
      detail: "connection failed"
    }
  end

  defp remote_probe_checks(%{remote_probe: probe, target: target}) do
    [
      remote_self_check(target, probe.remote_self),
      cluster_members_check(probe.cluster_members)
    ]
  end

  defp remote_self_check(target, %{status: :ok, value: value}) do
    if value == NodeName.to_node!(target, label: "target node") do
      %{label: "remote node identity", status: :ok, detail: Atom.to_string(value)}
    else
      %{label: "remote node identity", status: :error, detail: Atom.to_string(value)}
    end
  end

  defp remote_self_check(_target, %{status: status, detail: detail}) do
    %{label: "remote node identity", status: status, detail: detail}
  end

  defp cluster_members_check(%{status: :ok, value: %{live_nodes: live_nodes}}) do
    %{
      label: "remote Nix-Swarm API",
      status: :ok,
      detail: "live nodes: #{format_nodes(live_nodes)}"
    }
  end

  defp cluster_members_check(%{status: :ok, value: value}) do
    %{label: "remote Nix-Swarm API", status: :ok, detail: inspect(value)}
  end

  defp cluster_members_check(%{status: status, detail: detail}) do
    %{label: "remote Nix-Swarm API", status: status, detail: detail}
  end

  defp format_check_line(%{label: label, status: status, detail: detail}) do
    "  [#{format_check_status(status)}] #{label}: #{detail}"
  end

  defp format_check_status(:ok), do: "ok"
  defp format_check_status(:error), do: "fail"
  defp format_check_status(:info), do: "info"

  defp maybe_add_solution(solutions, nil), do: solutions
  defp maybe_add_solution(solutions, solution), do: solutions ++ [solution]

  defp target_resolution_solution(%{
         target_resolution: %{status: :error},
         target_host: target_host
       }) do
    "Use an IP or DNS name that resolves from the control machine. `#{target_host}` did not resolve here."
  end

  defp target_resolution_solution(_diagnostic), do: nil

  defp port_solution(diagnostic, port) do
    case Enum.find(
           diagnostic.target_port_checks,
           &String.contains?(&1.label, Integer.to_string(port))
         ) do
      %{status: :error} when port == @epmd_port ->
        "Make sure `nix-swarmd` is running on #{diagnostic.target_host} and TCP #{port} is open. If you want Nix-Swarm to manage the firewall, set `services.nix-swarm.openFirewall = true` and optionally scope it with `services.nix-swarm.firewallInterfaces`."

      %{status: :error} when port == @default_distribution_port ->
        "Make sure the target allows TCP #{port} for distributed Erlang. If you changed `services.nix-swarm.distributionPort`, open that port instead."

      _ ->
        nil
    end
  end

  defp connection_failure_solution(%{connect_result: false, cli_node: cli_node}) do
    "Verify the cookie matches on both nodes, and make sure the target can resolve and reach `#{cli_node}`. Distributed Erlang needs the target to reach the local control node name too."
  end

  defp connection_failure_solution(_diagnostic), do: nil

  defp name_override_solution(%{target_mode: :longnames, cli_name: nil} = diagnostic) do
    "Retry with `--name #{override_name_hint(diagnostic)}` if the auto-detected control host is not the right reachable LAN address."
  end

  defp name_override_solution(_diagnostic), do: nil

  defp remote_api_solution(%{remote_probe: %{cluster_members: %{status: :error}}}) do
    "The Erlang node answered, but `NixSwarm.API` did not. Make sure the `nix_swarm` application is running on the target."
  end

  defp remote_api_solution(_diagnostic), do: nil

  defp success_solution(%{
         connect_result: result,
         remote_probe: %{cluster_members: %{status: :ok}}
       })
       when result in [true, :ignored] do
    "This node is reachable for Nix-Swarm RPC. You can run cluster-wide status, map, reconcile, restart, and logs commands from here."
  end

  defp success_solution(_diagnostic), do: nil

  defp override_name_hint(%{cli_node: cli_node}) do
    cli_node
    |> Atom.to_string()
    |> String.split("@", parts: 2)
    |> List.last()
    |> then(&"nix-swarmctl@#{&1}")
  end

  defp override_name_hint(%{local_ip_candidates: [candidate | _]}) do
    "nix-swarmctl@#{candidate}"
  end

  defp result_label(true), do: "a direct distributed Erlang connection"
  defp result_label(:ignored), do: "the existing distributed Erlang connection"

  defp cli_node_source_label(nil), do: "auto-detected"
  defp cli_node_source_label(_name), do: "provided via --name"

  defp cookie_source_label(:provided), do: "command line"
  defp cookie_source_label(:cookie_file), do: "cookie file"
  defp cookie_source_label(:env), do: "NIX_SWARM_COOKIE"
  defp cookie_source_label(:env_file), do: "NIX_SWARM_COOKIE_FILE"

  defp format_list([]), do: "-"
  defp format_list(values), do: Enum.join(values, ", ")

  defp format_nodes(nodes), do: nodes |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")

  defp fail(message), do: raise(Error, message: message)
end
