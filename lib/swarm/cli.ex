defmodule Swarm.CLI do
  @moduledoc false

  @epmd_port 4369
  @default_distribution_port 4370
  @tcp_connect_timeout_ms 1_000

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
          summary: :boolean,
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
      ["help"] ->
        print_help()
        :ok

      ["defaults"] ->
        print_defaults(Keyword.get(opts, :source, "."))
        :ok

      ["doctor"] ->
        opts
        |> remote_options()
        |> diagnose_connection()
        |> print_doctor()

        :ok

      ["status"] ->
        with_remote(opts, fn target ->
          status = rpc!(target, Swarm.API, :cluster_status, [])

          if Keyword.get(opts, :summary, false) do
            print_status_summary(status)
          else
            print_status(status)
          end
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
          print_reconcile_result(rpc!(target, Swarm.API, :reconcile_cluster, []))
        end)

      ["restart", service_name] ->
        with_remote(opts, fn target ->
          print_restart_result(
            service_name,
            rpc!(target, Swarm.API, :restart_service, [service_name])
          )
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
        print_help()
        :ok
    end
  rescue
    error in [Error, ArgumentError, RuntimeError] ->
      {:error, Exception.message(error)}
  end

  defp with_remote(opts, callback) do
    target_node =
      opts
      |> remote_options()
      |> ensure_connection()

    callback.(target_node)
    :ok
  end

  defp remote_options(opts) do
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
      cli_name: Keyword.get(opts, :name)
    }
  end

  defp remote_cookie(opts) do
    cond do
      Keyword.has_key?(opts, :cookie) ->
        {Keyword.fetch!(opts, :cookie), :provided}

      Keyword.has_key?(opts, :cookie_file) ->
        {read_cookie_file!(Keyword.fetch!(opts, :cookie_file)), :cookie_file}

      System.get_env("SWARM_COOKIE") not in [nil, ""] ->
        {System.get_env("SWARM_COOKIE"), :env}

      System.get_env("SWARM_COOKIE_FILE") not in [nil, ""] ->
        {read_cookie_file!(System.get_env("SWARM_COOKIE_FILE")), :env_file}

      true ->
        fail(
          "missing cookie for remote command; pass --cookie or --cookie-file, or set SWARM_COOKIE / SWARM_COOKIE_FILE"
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

  defp ensure_connection(remote) do
    diagnostic = diagnose_connection(remote)

    case diagnostic.connect_result do
      result when result in [true, :ignored] ->
        diagnostic.target_node

      false ->
        fail(format_connection_error(diagnostic))
    end
  end

  defp diagnose_connection(%{target: target, cookie: cookie, cli_name: cli_name} = remote) do
    target_node = String.to_atom(target)
    {node_mode, target_host} = target_mode_and_host(target)
    %{name: cli_node_name} = cli_node_identity(target, cli_name)

    ensure_cli_node(cli_node_name, node_mode)
    Node.set_cookie(String.to_atom(cookie))

    target_resolution = resolve_host_details(target_host)
    target_port_checks = target_port_checks(node_mode, target_resolution)
    local_ip_candidates = local_ip_candidates()
    connect_result = Node.connect(target_node)
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

  defp target_port_checks(:shortnames, _target_resolution), do: []

  defp target_port_checks(_node_mode, %{status: :ok, address: address}) do
    [
      tcp_port_check(address, @epmd_port, "target epmd TCP port #{@epmd_port}"),
      tcp_port_check(
        address,
        @default_distribution_port,
        "target Swarm distribution TCP port #{@default_distribution_port}"
      )
    ]
  end

  defp target_port_checks(_node_mode, _target_resolution) do
    [
      %{
        label: "target epmd TCP port #{@epmd_port}",
        status: :info,
        detail: "skipped because the target host could not be resolved"
      },
      %{
        label: "target Swarm distribution TCP port #{@default_distribution_port}",
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
      cluster_members: rpc_probe(target_node, Swarm.API, :cluster_members, [])
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

  @doc false
  def format_connection_error(diagnostic) do
    """
    unable to connect to #{diagnostic.target}

    connection context:
      target node: #{diagnostic.target}
      target host: #{diagnostic.target_host || "shortname target"}
      target mode: #{diagnostic.target_mode}
      local CLI node: #{diagnostic.cli_node} (#{cli_node_source_label(diagnostic.cli_name)})
      cookie source: #{cookie_source_label(diagnostic.cookie_source)}
      local IP candidates: #{format_list(diagnostic.local_ip_candidates)}

    checks:
    #{Enum.map_join(diagnostic_checks(diagnostic), "\n", &format_check_line/1)}

    likely fixes:
    #{Enum.map_join(connection_solutions(diagnostic), "\n", &"  - #{&1}")}

    next step:
      rerun `swarm --target #{diagnostic.target} doctor` with the same cookie source for the full diagnostic report
    """
    |> String.trim()
  end

  @doc false
  def format_doctor_report(diagnostic) do
    heading = "doctor for #{diagnostic.target}"

    """
    #{heading}
    #{String.duplicate("=", String.length(heading))}
    connection context:
      target node: #{diagnostic.target}
      target host: #{diagnostic.target_host || "shortname target"}
      target mode: #{diagnostic.target_mode}
      local CLI node: #{diagnostic.cli_node} (#{cli_node_source_label(diagnostic.cli_name)})
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

  defp diagnostic_checks(diagnostic) do
    [resolution_check(diagnostic)]
    |> Kernel.++(diagnostic.target_port_checks)
    |> Kernel.++([connectivity_check(diagnostic)])
    |> Kernel.++(remote_probe_checks(diagnostic))
  end

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
    if value == String.to_atom(target) do
      %{label: "remote node identity", status: :ok, detail: Atom.to_string(value)}
    else
      %{label: "remote node identity", status: :error, detail: Atom.to_string(value)}
    end
  end

  defp remote_self_check(_target, %{status: status, detail: detail}) do
    %{label: "remote node identity", status: status, detail: detail}
  end

  defp cluster_members_check(%{status: :ok, value: %{live_nodes: live_nodes}}) do
    %{label: "remote Swarm API", status: :ok, detail: "live nodes: #{format_nodes(live_nodes)}"}
  end

  defp cluster_members_check(%{status: :ok, value: value}) do
    %{label: "remote Swarm API", status: :ok, detail: inspect(value)}
  end

  defp cluster_members_check(%{status: status, detail: detail}) do
    %{label: "remote Swarm API", status: status, detail: detail}
  end

  defp format_check_line(%{label: label, status: status, detail: detail}) do
    "  [#{format_check_status(status)}] #{label}: #{detail}"
  end

  defp format_check_status(:ok), do: "ok"
  defp format_check_status(:error), do: "fail"
  defp format_check_status(:info), do: "info"

  defp connection_solutions(diagnostic) do
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

  defp maybe_add_solution(solutions, nil), do: solutions
  defp maybe_add_solution(solutions, solution), do: solutions ++ [solution]

  defp target_resolution_solution(%{
         target_resolution: %{status: :error},
         target_host: target_host
       }) do
    "Use an IP or DNS name that resolves from the CLI machine. `#{target_host}` did not resolve here."
  end

  defp target_resolution_solution(_diagnostic), do: nil

  defp port_solution(diagnostic, port) do
    case Enum.find(
           diagnostic.target_port_checks,
           &String.contains?(&1.label, Integer.to_string(port))
         ) do
      %{status: :error} when port == @epmd_port ->
        "Make sure `swarmd` is running on #{diagnostic.target_host} and TCP #{port} is open. If you want Swarm to manage the firewall, set `services.swarm.openFirewall = true` and optionally scope it with `services.swarm.firewallInterfaces`."

      %{status: :error} when port == @default_distribution_port ->
        "Make sure the target allows TCP #{port} for distributed Erlang. If you changed `services.swarm.distributionPort`, open that port instead."

      _ ->
        nil
    end
  end

  defp connection_failure_solution(%{connect_result: false, cli_node: cli_node}) do
    "Verify the cookie matches on both nodes, and make sure the target can resolve and reach `#{cli_node}`. Distributed Erlang needs the target to reach the CLI node name too."
  end

  defp connection_failure_solution(_diagnostic), do: nil

  defp name_override_solution(%{target_mode: :longnames} = diagnostic) do
    "Retry with `--name #{override_name_hint(diagnostic)}` if the auto-detected CLI host is not the right reachable LAN address."
  end

  defp name_override_solution(_diagnostic), do: nil

  defp remote_api_solution(%{remote_probe: %{cluster_members: %{status: :error}}}) do
    "The Erlang node answered, but `Swarm.API` did not. Make sure the `swarm` application is running on the target."
  end

  defp remote_api_solution(_diagnostic), do: nil

  defp success_solution(%{
         connect_result: result,
         remote_probe: %{cluster_members: %{status: :ok}}
       })
       when result in [true, :ignored] do
    "This node is reachable for Swarm RPC. You can run cluster-wide status, map, reconcile, restart, and logs commands from here."
  end

  defp success_solution(_diagnostic), do: nil

  defp override_name_hint(%{local_ip_candidates: [candidate | _]}) do
    "swarmctl@#{candidate}"
  end

  defp override_name_hint(%{cli_node: cli_node}) do
    cli_node
    |> Atom.to_string()
    |> String.split("@", parts: 2)
    |> List.last()
    |> then(&"swarmctl@#{&1}")
  end

  defp doctor_result(%{connect_result: result, remote_probe: %{cluster_members: %{status: :ok}}})
       when result in [true, :ignored] do
    "The target is reachable and the Swarm API responded. This machine can control the cluster through #{result_label(result)}."
  end

  defp doctor_result(%{connect_result: result}) when result in [true, :ignored] do
    "The Erlang connection worked, but the target did not answer the Swarm API cleanly."
  end

  defp doctor_result(_diagnostic) do
    "Issues were detected. Fix the failed checks above, then rerun `doctor` or your original command."
  end

  defp result_label(true), do: "a direct distributed Erlang connection"
  defp result_label(:ignored), do: "the existing distributed Erlang connection"

  defp cli_node_source_label(nil), do: "auto-detected"
  defp cli_node_source_label(_name), do: "provided via --name"

  defp cookie_source_label(:provided), do: "command line"
  defp cookie_source_label(:cookie_file), do: "cookie file"
  defp cookie_source_label(:env), do: "SWARM_COOKIE"
  defp cookie_source_label(:env_file), do: "SWARM_COOKIE_FILE"

  defp format_list([]), do: "-"
  defp format_list(values), do: Enum.join(values, ", ")

  defp format_nodes(nodes), do: nodes |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")

  defp print_defaults(source) do
    apply_defaults = Swarm.Deploy.defaults(source)
    bootstrap_defaults = Swarm.Bootstrap.defaults()

    output =
      [
        render_heading("defaults"),
        "",
        render_section(
          "remote commands",
          render_table(
            ["setting", "value"],
            [
              [
                "cookie",
                "required via --cookie, --cookie-file, SWARM_COOKIE, or SWARM_COOKIE_FILE"
              ],
              ["logs --lines", "50"],
              ["--name", "auto-detected from the route to the target"],
              ["doctor checks", "target resolution, TCP 4369, TCP 4370, remote Swarm API"]
            ]
          )
        ),
        "",
        render_section(
          "apply",
          render_table(
            ["setting", "value"],
            [
              ["source", apply_defaults.source],
              ["hosts", format_list(apply_defaults.hosts)],
              ["host source", apply_defaults.host_source],
              ["remote path", apply_defaults.remote_path],
              ["nixos dir", apply_defaults.nixos_dir],
              ["default behavior", "validate -> preview plan -> apply all hosts"],
              [
                "common overrides",
                "--hosts, --source, --remote-path, --nixos-dir, --dry-run, --flake, --build-host"
              ]
            ]
          )
        ),
        "",
        render_section(
          "add-machine",
          render_table(
            ["setting", "value"],
            [
              ["cluster module", bootstrap_defaults.cluster_module],
              ["module ref", bootstrap_defaults.module_ref],
              ["package", bootstrap_defaults.package_ref]
            ]
          )
        ),
        "",
        render_section(
          "Nix module defaults",
          render_table(
            ["setting", "value"],
            [
              ["services.swarm.package", "import ./package.nix { inherit pkgs; }"],
              ["services.swarm.openFirewall", "false"],
              ["services.swarm.firewallInterfaces", "[]"],
              ["services.swarm.epmdPort", "4369"],
              ["services.swarm.distributionPort", "4370"],
              ["services.swarm.runtime.connectIntervalMs", "500"],
              ["services.swarm.runtime.reconcileIntervalMs", "500"],
              ["services.swarm.runtime.generation", "\"nixos\""],
              ["services.swarm.services.<name>.replicas", "1"],
              [
                "services.swarm.services.<name>.unitTemplate",
                "#{Swarm.Service.default_unit_template(1)} when replicas = 1, #{Swarm.Service.default_unit_template(2)} when replicas > 1"
              ],
              ["services.swarm.services.<name>.constraints", "[]"],
              ["services.swarm.services.<name>.preferredNodes", "[]"],
              ["services.swarm.services.<name>.settings", "{}"],
              ["services.swarm.ingress.sites.<name>.scheme", "\"http\""],
              ["services.swarm.ingress.sites.<name>.websocket", "true"],
              ["services.swarm.ingress.sites.<name>.clientMaxBodySize", "\"64m\""],
              ["services.swarm.ingress.sites.<name>.default", "false"]
            ]
          )
        )
      ]
      |> Enum.join("\n")

    IO.puts(output)
  end

  defp print_help do
    output =
      [
        render_heading("usage"),
        "",
        render_section(
          "setup",
          render_table(
            ["command", "description"],
            [
              [
                "export SWARM_COOKIE_FILE=./secrets/swarm.cookie",
                "Optional shell default so remote commands can stay short without exposing the cookie in `ps`."
              ]
            ]
          )
        ),
        "",
        render_section(
          "commands",
          render_table(
            ["command", "description"],
            [
              ["swarm defaults", "Show the effective CLI and Nix default values."],
              [
                "swarm --target node-a@127.0.0.1 status",
                "Show cluster status, placements, and per-node unit state."
              ],
              [
                "swarm --target node-a@127.0.0.1 status --summary",
                "Show one compact line per live node and service."
              ],
              [
                "swarm --target node-a@127.0.0.1 cluster members",
                "Show configured peers and currently live nodes."
              ],
              [
                "swarm --target node-a@127.0.0.1 cluster map",
                "Show an ASCII map of nodes and service slot ownership."
              ],
              [
                "swarm --target node-a@127.0.0.1 doctor",
                "Diagnose remote-node reachability, naming, ports, and Swarm RPC."
              ],
              [
                "swarm --target node-a@127.0.0.1 restart SERVICE",
                "Restart the named service on every live owner node."
              ],
              [
                "swarm --target node-a@127.0.0.1 logs SERVICE --lines 100",
                "Show recent logs for each live owner of the service."
              ],
              [
                "swarm --target node-a@127.0.0.1 reconcile",
                "Force an immediate reconciliation across live nodes."
              ],
              [
                "swarm add-machine --output ./machines/node-d.nix --node-name node-d@10.0.0.14 --cookie-file ../secrets/swarm.cookie",
                "Generate a machine bootstrap file for a new Swarm node."
              ],
              [
                "swarm add-machine --output ./machines/node-d.nix --node-name node-d@10.0.0.14 --cookie-file ../secrets/swarm.cookie --hosts root@10.0.0.14 --deploy",
                "Generate a machine file and deploy it to the new host over SSH."
              ],
              [
                "swarm apply --dry-run",
                "Validate the cluster config and print the rollout plan for all machine files."
              ],
              ["swarm apply", "Validate, preview, and apply to all machine files by default."],
              [
                "swarm apply --hosts root@10.0.0.14,root@10.0.0.15 --source . --remote-path /etc/nixos/nix-swarm",
                "Override the source checkout or remote repo path used during apply."
              ]
            ]
          )
        ),
        "",
        render_section(
          "notes",
          render_bullets([
            "remote commands can target any reachable Swarm node",
            "remote commands need --cookie, --cookie-file, SWARM_COOKIE, or SWARM_COOKIE_FILE",
            "longname targets need the target to reach the CLI node back over distributed Erlang",
            "pass --name swarmctl@YOUR_IP if local host auto-detection is wrong"
          ])
        )
      ]
      |> Enum.join("\n")

    IO.puts(output)
  end

  defp print_doctor(diagnostic), do: IO.puts(render_doctor_report(diagnostic))

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

  defp print_error(message), do: IO.puts(:stderr, "#{paint("error", :error)}: #{message}")

  defp print_members(%{
         queried_node: queried_node,
         configured_nodes: configured_nodes,
         live_nodes: live_nodes
       }) do
    nodes =
      (configured_nodes ++ live_nodes)
      |> Enum.uniq()
      |> Enum.sort_by(&Atom.to_string/1)

    output =
      [
        render_heading("cluster members"),
        "",
        render_section(
          "overview",
          render_table(
            ["field", "value"],
            [
              ["queried node", Atom.to_string(queried_node)],
              ["configured", format_nodes(configured_nodes)],
              ["live", format_nodes(live_nodes)]
            ]
          )
        ),
        "",
        render_section(
          "nodes",
          render_table(
            ["node", "configured", "live"],
            Enum.map(nodes, fn node ->
              [
                cell(Atom.to_string(node), :info),
                yes_no_cell(node in configured_nodes, :configured),
                yes_no_cell(node in live_nodes, :live)
              ]
            end)
          )
        )
      ]
      |> Enum.join("\n")

    IO.puts(output)
  end

  defp print_status(%{
         queried_node: queried_node,
         live_nodes: live_nodes,
         placements: placements,
         nodes: nodes
       }) do
    placement_rows =
      placements
      |> Enum.sort_by(fn {service, _slots} -> service end)
      |> Enum.flat_map(fn {service, slots} ->
        slots
        |> Enum.sort_by(& &1.slot)
        |> Enum.map(fn slot ->
          [
            cell(service, :accent),
            Integer.to_string(slot.slot),
            owner_cell(slot.owner),
            cell(slot.unit, :info)
          ]
        end)
      end)
      |> default_table_rows(4)

    node_service_rows =
      nodes
      |> Enum.sort_by(fn {node, _status} -> Atom.to_string(node) end)
      |> Enum.flat_map(fn {node, status} ->
        case status do
          %{services: services} ->
            Enum.map(services, fn service ->
              running = Enum.count(service.units, &(&1.status == :running))

              [
                cell(Atom.to_string(node), live_node_tone(node, live_nodes)),
                cell(service.name, :accent),
                format_slots(service.local_owned_slots),
                "#{running}/#{length(service.units)}"
              ]
            end)

          other ->
            [[cell(Atom.to_string(node), :warning), inspect(other), "-", "-"]]
        end
      end)
      |> default_table_rows(4)

    unit_rows =
      nodes
      |> Enum.sort_by(fn {node, _status} -> Atom.to_string(node) end)
      |> Enum.flat_map(fn {node, status} ->
        case status do
          %{services: services} ->
            Enum.flat_map(services, fn service ->
              Enum.map(service.units, fn unit ->
                [
                  cell(Atom.to_string(node), live_node_tone(node, live_nodes)),
                  cell(service.name, :accent),
                  cell(unit.unit, :info),
                  owner_cell(unit.owner),
                  status_cell(unit.status)
                ]
              end)
            end)

          _other ->
            []
        end
      end)
      |> default_table_rows(5)

    output =
      [
        render_heading("cluster status"),
        "",
        render_section(
          "overview",
          render_table(
            ["field", "value"],
            [
              ["queried node", Atom.to_string(queried_node)],
              ["live nodes", format_nodes(live_nodes)]
            ]
          )
        ),
        "",
        render_section(
          "placements",
          render_table(["service", "slot", "owner", "unit"], placement_rows)
        ),
        "",
        render_section(
          "node services",
          render_table(["node", "service", "owned slots", "running"], node_service_rows)
        ),
        "",
        render_section(
          "units",
          render_table(["node", "service", "unit", "owner", "status"], unit_rows)
        )
      ]
      |> Enum.join("\n")

    IO.puts(output)
  end

  defp print_status_summary(status), do: IO.puts(format_status_summary(status))

  defp format_status_summary(%{
         queried_node: queried_node,
         live_nodes: live_nodes,
         placements: placements,
         nodes: nodes
       }) do
    node_rows =
      nodes
      |> Enum.sort_by(fn {node, _status} -> Atom.to_string(node) end)
      |> Enum.map(fn {node, status} ->
        case status do
          %{services: services} ->
            units = Enum.flat_map(services, & &1.units)

            owned_slots =
              services
              |> Enum.flat_map(fn service ->
                Enum.map(service.local_owned_slots, fn slot -> "#{service.name}[#{slot}]" end)
              end)
              |> format_list()

            running = Enum.count(units, &(&1.status == :running))

            [
              cell(Atom.to_string(node), live_node_tone(node, live_nodes)),
              owned_slots,
              "#{running}/#{length(units)}"
            ]

          other ->
            [cell(Atom.to_string(node), :warning), inspect(other), "-"]
        end
      end)
      |> default_table_rows(3)

    service_rows =
      placements
      |> Enum.sort_by(fn {service, _slots} -> service end)
      |> Enum.map(fn {service, slots} ->
        placement_summary =
          slots
          |> Enum.sort_by(& &1.slot)
          |> Enum.map(fn slot ->
            "#{slot.slot}=#{owner_display(slot.owner)}"
          end)
          |> Enum.join(", ")

        [cell(service, :accent), Integer.to_string(length(slots)), placement_summary]
      end)
      |> default_table_rows(3)

    [
      render_heading("cluster summary"),
      "",
      render_section(
        "overview",
        render_table(
          ["field", "value"],
          [
            ["queried node", Atom.to_string(queried_node)],
            ["live nodes", format_nodes(live_nodes)]
          ]
        )
      ),
      "",
      render_section("nodes", render_table(["node", "owned", "running"], node_rows)),
      "",
      render_section(
        "services",
        render_table(["service", "replicas", "placements"], service_rows)
      )
    ]
    |> Enum.join("\n")
  end

  defp print_logs(logs) do
    summary_rows =
      logs
      |> Enum.sort_by(fn {node, _entries} -> Atom.to_string(node) end)
      |> Enum.flat_map(fn {node, entries} ->
        Enum.map(entries, fn entry ->
          [
            cell(Atom.to_string(node), :info),
            cell(entry.unit, :accent),
            Integer.to_string(log_line_count(entry.logs))
          ]
        end)
      end)
      |> default_table_rows(3)

    detail_lines =
      logs
      |> Enum.sort_by(fn {node, _entries} -> Atom.to_string(node) end)
      |> Enum.flat_map(fn {node, entries} ->
        node_heading = render_subheading("node #{node}")

        entry_lines =
          Enum.flat_map(entries, fn entry ->
            logs_output =
              case String.split(entry.logs, "\n", trim: true) do
                [] -> ["  <no logs>"]
                lines -> Enum.map(lines, &"  #{&1}")
              end

            [paint(entry.unit, :accent) | logs_output] ++ [""]
          end)

        [node_heading] ++ entry_lines
      end)
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()

    IO.puts(
      [
        render_heading("service logs"),
        "",
        render_section("summary", render_table(["node", "unit", "lines"], summary_rows)),
        if(detail_lines == [], do: nil, else: ""),
        if(detail_lines == [],
          do: nil,
          else: render_section("details", Enum.join(detail_lines, "\n"))
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    )
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

    node_lines =
      configured_nodes
      |> Enum.sort_by(&Atom.to_string/1)
      |> Enum.with_index()
      |> Enum.flat_map(fn {node, index} ->
        last_node? = index == length(configured_nodes) - 1
        connector = ascii_tree_connector(last_node?)
        continuation = ascii_tree_continuation(last_node?)

        state =
          if MapSet.member?(live_nodes, node),
            do: status_cell_text(:up),
            else: status_cell_text(:down)

        head = "#{connector} #{paint(Atom.to_string(node), :info)} #{state}"

        slot_lines =
          case Map.get(owned_by_node, node, []) |> Enum.sort_by(&{&1.service, &1.slot}) do
            [] ->
              ["#{continuation}#{ascii_tree_connector(true)} #{paint("idle", :muted)}"]

            slots ->
              slots
              |> Enum.with_index()
              |> Enum.map(fn {slot, slot_index} ->
                "#{continuation}#{ascii_tree_connector(slot_index == length(slots) - 1)} #{paint(slot.service, :accent)} slot #{slot.slot} (#{paint(slot.unit, :info)})"
              end)
          end

        [head | slot_lines]
      end)

    service_rows =
      status.placements
      |> Enum.sort_by(fn {service, _slots} -> service end)
      |> Enum.flat_map(fn {service, slots} ->
        slots
        |> Enum.sort_by(& &1.slot)
        |> Enum.map(fn slot ->
          [
            cell(service, :accent),
            Integer.to_string(slot.slot),
            owner_cell(slot.owner),
            cell(slot.unit, :info)
          ]
        end)
      end)
      |> default_table_rows(4)

    IO.puts(
      [
        render_heading("cluster map"),
        "",
        render_section("nodes", Enum.join(node_lines, "\n")),
        "",
        render_section(
          "services",
          render_table(["service", "slot", "owner", "unit"], service_rows)
        )
      ]
      |> Enum.join("\n")
    )
  end

  defp print_bootstrap_result(%{output: output, deployed: false}) do
    IO.puts(
      [
        render_heading("machine bootstrap"),
        "",
        render_section(
          "result",
          render_table(
            ["field", "value"],
            [
              ["output", output],
              ["deployed", "no"]
            ]
          )
        ),
        "",
        render_section(
          "next step",
          "update cluster/cluster.nix, add any service files under cluster/services/, then run swarm apply or nixos-rebuild"
        )
      ]
      |> Enum.join("\n")
    )
  end

  defp print_bootstrap_result(%{output: output, deployed: true, deploy_output: deploy_output}) do
    IO.puts(
      [
        render_heading("machine bootstrap"),
        "",
        render_section(
          "result",
          render_table(
            ["field", "value"],
            [
              ["output", output],
              ["deployed", "yes"]
            ]
          )
        ),
        ""
      ]
      |> Enum.join("\n")
    )

    print_apply_result(deploy_output)
  end

  defp print_apply_result(%{dry_run: true, validation: validation, results: results}) do
    IO.puts("#{paint("dry run complete", :success)}: configuration validated")
    print_apply_preview(validation, results)
  end

  defp print_apply_result(%{validation: validation, results: results}) do
    IO.puts("#{paint("preflight complete", :success)}: configuration validated")
    print_apply_preview(validation, results)
    IO.puts("")
    IO.puts(paint("apply complete", :success))

    IO.puts(
      render_table(
        ["host", "result"],
        Enum.map(results, fn %{host: host} ->
          [cell(host, :info), cell("applied cluster config", :success)]
        end)
      )
    )
  end

  defp print_apply_preview(validation, results) do
    IO.puts(
      [
        render_section(
          "validated machine files",
          render_table(
            ["file"],
            validation.machine_files
            |> Enum.map(&[Path.relative_to_cwd(&1)])
            |> default_table_rows(1)
          )
        ),
        "",
        render_section(
          "planned commands",
          render_table(
            ["host", "sync command", "rebuild command"],
            results
            |> Enum.map(fn %{
                             host: host,
                             sync_command: sync_command,
                             rebuild_command: rebuild_command
                           } ->
              [cell(host, :info), sync_command, rebuild_command]
            end)
            |> default_table_rows(3)
          )
        )
      ]
      |> Enum.join("\n")
    )
  end

  defp print_restart_result(service_name, results) do
    rows =
      results
      |> Enum.sort_by(fn {node, _entries} -> Atom.to_string(node) end)
      |> Enum.flat_map(fn {node, entries} ->
        case entries do
          [] ->
            [[cell(Atom.to_string(node), :warning), "-", cell("no local units", :warning)]]

          node_entries ->
            Enum.map(node_entries, fn {unit, result} ->
              [cell(Atom.to_string(node), :info), cell(unit, :accent), result_cell(result)]
            end)
        end
      end)

    rows =
      if rows == [] do
        [[cell("-", :muted), cell("-", :muted), cell("no live owners", :warning)]]
      else
        rows
      end

    IO.puts(
      [
        render_heading("restart #{service_name}"),
        "",
        render_table(["node", "unit", "result"], rows)
      ]
      |> Enum.join("\n")
    )
  end

  defp print_reconcile_result(results) do
    owned_rows =
      results
      |> Enum.sort_by(fn {node, _result} -> Atom.to_string(node) end)
      |> Enum.map(fn {node, result} ->
        [cell(Atom.to_string(node), :info), format_list(result.owned_units)]
      end)
      |> default_table_rows(2)

    result_rows =
      results
      |> Enum.sort_by(fn {node, _result} -> Atom.to_string(node) end)
      |> Enum.flat_map(fn {node, result} ->
        Enum.map(result.results, fn {unit, unit_result} ->
          [cell(Atom.to_string(node), :info), cell(unit, :accent), result_cell(unit_result)]
        end)
      end)
      |> default_table_rows(3)

    IO.puts(
      [
        render_heading("reconcile"),
        "",
        render_section("owned units", render_table(["node", "owned units"], owned_rows)),
        "",
        render_section("unit results", render_table(["node", "unit", "result"], result_rows))
      ]
      |> Enum.join("\n")
    )
  end

  defp render_doctor_report(diagnostic) do
    checks_rows =
      diagnostic_checks(diagnostic)
      |> Enum.map(fn %{label: label, status: status, detail: detail} ->
        [status_cell(status), label, detail]
      end)

    context_rows = [
      ["target node", diagnostic.target],
      ["target host", diagnostic.target_host || "shortname target"],
      ["target mode", diagnostic.target_mode],
      [
        "local CLI node",
        "#{diagnostic.cli_node} (#{cli_node_source_label(diagnostic.cli_name)})"
      ],
      ["cookie source", cookie_source_label(diagnostic.cookie_source)],
      ["local IP candidates", format_list(diagnostic.local_ip_candidates)]
    ]

    [
      render_heading("doctor for #{diagnostic.target}"),
      "",
      render_section("connection context", render_table(["field", "value"], context_rows)),
      "",
      render_section("checks", render_table(["status", "check", "detail"], checks_rows)),
      "",
      render_section("result", doctor_result(diagnostic)),
      "",
      render_section("fixes and next steps", render_bullets(connection_solutions(diagnostic)))
    ]
    |> Enum.join("\n")
  end

  defp render_heading(title) do
    [
      paint(title, :title),
      paint(String.duplicate("-", String.length(title)), :title)
    ]
    |> Enum.join("\n")
  end

  defp render_subheading(title) do
    [
      paint(title, :section),
      paint(String.duplicate("-", String.length(title)), :section)
    ]
    |> Enum.join("\n")
  end

  defp render_section(title, body) do
    [render_subheading(title), body]
    |> Enum.join("\n")
  end

  defp render_bullets(items) do
    items
    |> Enum.map(&"- #{&1}")
    |> Enum.join("\n")
  end

  defp render_table(headers, rows) do
    headers = Enum.map(headers, &cell(&1, :label))
    rows = Enum.map(rows, fn row -> Enum.map(row, &normalize_cell/1) end)
    widths = column_widths(headers, rows)
    border = table_border(widths)

    body =
      rows
      |> Enum.map_join("\n", &render_table_row(&1, widths))

    [border, render_table_row(headers, widths), border, body, border]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp render_table_row(cells, widths) do
    lines_per_cell = Enum.map(cells, &String.split(&1.text, "\n", trim: false))
    height = lines_per_cell |> Enum.map(&length/1) |> Enum.max(fn -> 1 end)

    0..(height - 1)
    |> Enum.map_join("\n", fn line_index ->
      rendered_cells =
        cells
        |> Enum.with_index()
        |> Enum.map_join(" | ", fn {current_cell, column_index} ->
          line =
            current_cell.text
            |> String.split("\n", trim: false)
            |> Enum.at(line_index, "")

          line
          |> String.pad_trailing(Enum.at(widths, column_index))
          |> paint(current_cell.tone)
        end)

      "| #{rendered_cells} |"
    end)
  end

  defp table_border(widths) do
    "+" <>
      Enum.map_join(widths, "+", fn width ->
        String.duplicate("-", width + 2)
      end) <> "+"
  end

  defp column_widths(headers, rows) do
    cells = [headers | rows]
    column_count = length(headers)

    for index <- 0..(column_count - 1) do
      cells
      |> Enum.map(fn row ->
        row
        |> Enum.at(index)
        |> max_cell_width()
      end)
      |> Enum.max(fn -> 1 end)
    end
  end

  defp max_cell_width(nil), do: 1

  defp max_cell_width(cell) do
    cell.text
    |> String.split("\n", trim: false)
    |> Enum.map(&String.length/1)
    |> Enum.max(fn -> 1 end)
  end

  defp normalize_cell(%{text: _text, tone: _tone} = cell), do: cell
  defp normalize_cell({text, tone}), do: cell(text, tone)
  defp normalize_cell(text), do: cell(text)

  defp cell(value, tone \\ nil)
  defp cell(nil, tone), do: %{text: "-", tone: tone}
  defp cell(value, tone), do: %{text: to_string(value), tone: tone}

  defp default_table_rows(rows, width, placeholder \\ "-")

  defp default_table_rows([], width, placeholder) do
    [List.duplicate(placeholder, width)]
  end

  defp default_table_rows(rows, _width, _placeholder), do: rows

  defp paint(text, tone) do
    styles = tone_styles(tone)
    content = to_string(text)

    if styles == [] do
      content
    else
      IO.ANSI.format(styles ++ [content, :reset], IO.ANSI.enabled?())
      |> IO.iodata_to_binary()
    end
  end

  defp tone_styles(nil), do: []
  defp tone_styles(styles) when is_list(styles), do: styles
  defp tone_styles(:title), do: [:bright, :cyan]
  defp tone_styles(:section), do: [:bright, :blue]
  defp tone_styles(:label), do: [:bright]
  defp tone_styles(:info), do: [:cyan]
  defp tone_styles(:accent), do: [:magenta]
  defp tone_styles(:success), do: [:green]
  defp tone_styles(:warning), do: [:yellow]
  defp tone_styles(:error), do: [:red]
  defp tone_styles(:muted), do: [:light_black]

  defp live_node_tone(node, live_nodes) do
    if node in live_nodes, do: :success, else: :error
  end

  defp owner_display(nil), do: "unplaced"
  defp owner_display(owner), do: Atom.to_string(owner)

  defp owner_cell(owner) do
    cell(owner_display(owner), if(owner, do: :info, else: :warning))
  end

  defp format_slots([]), do: "-"

  defp format_slots(slots) do
    slots
    |> Enum.sort()
    |> Enum.map_join(", ", &Integer.to_string/1)
  end

  defp yes_no_cell(true, :configured), do: cell("yes", :success)
  defp yes_no_cell(false, :configured), do: cell("no", :muted)
  defp yes_no_cell(true, :live), do: cell("yes", :success)
  defp yes_no_cell(false, :live), do: cell("no", :error)

  defp status_cell(status), do: cell(status_to_text(status), status_tone(status))

  defp status_cell_text(status) do
    status
    |> status_to_text()
    |> then(&"[#{paint(&1, status_tone(status))}]")
  end

  defp result_cell(:ok), do: cell("ok", :success)
  defp result_cell(result), do: cell(inspect(result), :warning)

  defp status_to_text(status) when is_atom(status), do: Atom.to_string(status)
  defp status_to_text(status), do: to_string(status)

  defp status_tone(status) when status in [:ok, :running, :up, true], do: :success
  defp status_tone(status) when status in [:error, :fail, :down, false], do: :error
  defp status_tone(status) when status in [:info, :stopped, :unplaced, :unknown], do: :warning
  defp status_tone(_status), do: :info

  defp ascii_tree_connector(true), do: "`-"
  defp ascii_tree_connector(false), do: "|-"
  defp ascii_tree_continuation(true), do: "  "
  defp ascii_tree_continuation(false), do: "| "

  defp log_line_count(""), do: 0

  defp log_line_count(logs) do
    logs
    |> String.split("\n", trim: true)
    |> length()
  end
end
