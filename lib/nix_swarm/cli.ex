defmodule NixSwarm.CLI do
  @moduledoc false

  alias NixSwarm.ConfigFiles

  @strict_opts [
    help: :boolean,
    version: :boolean,
    target: :string,
    ssh_host: :string,
    secret_file: :string,
    name: :string,
    lines: :integer,
    refresh_ms: :integer,
    source: :string,
    cluster_file: :string,
    machines_dir: :string,
    services_dir: :string,
    flake: :string,
    host: :string,
    hosts: :string,
    command_timeout_ms: :integer,
    yes: :boolean,
    json: :boolean
  ]

  def main(argv) do
    case run(argv) do
      :ok ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, "error: #{message}")
        System.halt(1)
    end
  end

  def run(argv, tui_runner \\ &NixSwarm.TUI.run/1, dependencies \\ []) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @strict_opts)
    validate_parse_result!(opts, invalid)
    # Help and version must remain side-effect free. In particular, resolving a
    # default SSH host can evaluate a flake, which requires the operator
    # supervision tree in packaged `eval` invocations.
    opts =
      if Keyword.get(opts, :help, false) or Keyword.get(opts, :version, false),
        do: opts,
        else: maybe_apply_launch_defaults(args, opts)

    validate_json_scope!(args, opts)

    plan_fun = Keyword.get(dependencies, :plan_fun, &NixSwarm.Deploy.run/1)
    deploy_fun = Keyword.get(dependencies, :deploy_fun, &NixSwarm.Deploy.run/1)
    rollback_fun = Keyword.get(dependencies, :rollback_fun, &NixSwarm.Deploy.rollback/1)
    credentials_fun = Keyword.get(dependencies, :credentials_fun, &NixSwarm.Credentials.install/1)
    upgrade_fun = Keyword.get(dependencies, :upgrade_fun, &NixSwarm.Upgrade.run/2)
    restart_fun = Keyword.get(dependencies, :restart_fun, &NixSwarm.ServiceRestart.run/1)

    cond do
      Keyword.get(opts, :version, false) ->
        IO.puts(NixSwarm.release_label())
        :ok

      Keyword.get(opts, :help, false) ->
        print_help()
        :ok

      args == ["cluster", "plan"] ->
        plan = plan_fun.(deploy_options(opts, true))
        print_deploy_plan(plan)
        :ok

      args == ["cluster", "apply"] ->
        require_confirmation!(opts, "cluster apply")

        result = deploy_fun.(deploy_options(opts, false))
        print_deploy_result(result)
        :ok

      args == ["cluster", "rollback"] ->
        require_confirmation!(opts, "cluster rollback")
        result = rollback_fun.(deploy_options(opts, false))
        print_deploy_result(result)
        :ok

      args == ["cluster", "credentials", "rotate"] ->
        require_confirmation!(opts, "cluster credentials rotate")

        result =
          credentials_fun.(Keyword.put(deploy_options(opts, false), :rotate_credentials, true))

        IO.puts(
          "Installed cluster credential #{result.fingerprint} on #{length(result.hosts)} host(s)."
        )

        :ok

      args == ["cluster", "upgrade"] ->
        require_confirmation!(opts, "cluster upgrade")
        result = upgrade_fun.(deploy_options(opts, false), deploy_fun)
        print_deploy_result(result.deploy)
        :ok

      args == ["cluster", "doctor"] ->
        remote =
          opts
          |> Keyword.take([:target, :ssh_host])
          |> NixSwarm.Remote.options!()

        diagnostic = NixSwarm.Remote.diagnose_connection(remote)
        IO.puts(NixSwarm.Remote.format_doctor_report(diagnostic))

        if NixSwarm.Remote.connected?(diagnostic),
          do: :ok,
          else: {:error, "cluster connectivity checks failed"}

      args == ["service", "logs"] ->
        service_name = opts |> Keyword.fetch!(:name) |> String.trim()
        lines = Keyword.get(opts, :lines, 50)
        remote_opts = Keyword.take(opts, [:target, :ssh_host])

        with {:ok, target_node} <- connect_remote(remote_opts),
             overview <- NixSwarm.Remote.rpc!(target_node, NixSwarm.API, :cluster_overview, []),
             :ok <- validate_service_name(overview, service_name),
             logs <- NixSwarm.Remote.rpc!(target_node, NixSwarm.API, :logs, [service_name, lines]) do
          if Keyword.get(opts, :json, false) do
            print_json!(%{service: service_name, logs: logs})
          else
            print_service_logs(logs)
          end

          :ok
        else
          {:error, msg} -> {:error, msg}
        end

      args == ["service", "restart"] ->
        require_confirmation!(opts, "service restart")
        service_name = opts |> Keyword.fetch!(:name) |> String.trim()
        remote_opts = Keyword.take(opts, [:target, :ssh_host])

        remote_opts =
          case Keyword.get(dependencies, :query_fun) do
            query_fun when is_function(query_fun, 2) ->
              Keyword.put(remote_opts, :query_fun, query_fun)

            _ ->
              remote_opts
          end

        with {:ok, target_node} <- connect_remote(remote_opts),
             overview <- NixSwarm.Remote.rpc!(target_node, NixSwarm.API, :cluster_overview, []),
             :ok <- validate_service_name(overview, service_name),
             units <- restart_units(overview, service_name),
             {:ok, result} <-
               restart_fun.(
                 remote: target_node,
                 overview: overview,
                 service: service_name,
                 units: units,
                 command_fun: Keyword.get(dependencies, :command_fun, &run_command/2)
               ) do
          if Keyword.get(opts, :json, false) do
            print_json!(result)
          else
            IO.puts("Restarted #{length(units)} unit(s) for #{service_name}.")
          end

          :ok
        else
          {:error, msg} -> {:error, msg}
        end

      args == ["cluster", "status"] ->
        remote_opts = Keyword.take(opts, [:target, :ssh_host])

        with {:ok, target_node} <- connect_remote(remote_opts),
             overview <- NixSwarm.Remote.rpc!(target_node, NixSwarm.API, :cluster_overview, []) do
          if Keyword.get(opts, :json, false),
            do: print_json!(overview),
            else: print_cluster_status(overview)

          :ok
        else
          {:error, msg} -> {:error, msg}
        end

      args == ["debug", "state"] ->
        {:error, "debug state is intentionally unavailable through the read-only operator API"}

      args in [["cluster", "init"], ["cluster", "ensure"], ["cluster", "rebuild"]] ->
        {:error, "command removed; use `nix-swarm cluster apply --yes`"}

      args == ["cluster", "members"] ->
        {:error, "command removed; use `nix-swarm cluster status`"}

      args == ["cluster", "credentials"] ->
        {:error, "command removed; use `nix-swarm cluster credentials rotate --yes`"}

      args == ["cluster", "upgrade", "prepare"] ->
        {:error, "command removed; use `nix-swarm cluster upgrade --yes`"}

      args in [["service", "create"], ["service", "add"], ["service", "list"]] ->
        {:error, "command removed; copy the service definition from `examples/starter`"}

      args in [[], ["tui"], ["help"]] ->
        if args == ["help"] do
          print_help()
          :ok
        else
          tui_runner.(opts)
        end

      true ->
        {:error, legacy_command_error(args)}
    end
  rescue
    error in [NixSwarm.Remote.Error, ArgumentError, RuntimeError] ->
      {:error, Exception.message(error)}
  end

  defp validate_parse_result!(_opts, [{option, nil} | _invalid]) do
    raise ArgumentError, "unsupported option: #{option}"
  end

  defp validate_parse_result!(_opts, [{option, value} | _invalid]) do
    raise ArgumentError, "invalid value for #{option}: #{value}"
  end

  defp validate_parse_result!(opts, []) do
    validate_integer_range!(opts, :lines, "--lines", 1, 1_000)
    validate_integer_range!(opts, :refresh_ms, "--refresh-ms", 100, 600_000)
    validate_integer_range!(opts, :command_timeout_ms, "--command-timeout-ms", 1, 86_400_000)
  end

  defp validate_json_scope!(args, opts) do
    cond do
      not Keyword.get(opts, :json, false) ->
        :ok

      args in [["cluster", "status"], ["service", "logs"]] ->
        :ok

      true ->
        raise ArgumentError,
              "--json is supported only for cluster status and service logs"
    end
  end

  defp validate_integer_range!(opts, key, label, minimum, maximum) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value >= minimum and value <= maximum -> :ok
      _value -> raise ArgumentError, "#{label} must be between #{minimum} and #{maximum}"
    end
  end

  defp apply_launch_defaults(opts) do
    config_paths = config_paths(opts)

    opts
    |> maybe_put_default_target(config_paths)
    |> maybe_put_default_ssh_host(config_paths)
  end

  defp maybe_apply_launch_defaults(args, opts) do
    if requires_remote_options?(args), do: apply_launch_defaults(opts), else: opts
  end

  defp requires_remote_options?(args) do
    args in [
      [],
      ["tui"],
      ["cluster", "doctor"],
      ["cluster", "status"],
      ["service", "logs"],
      ["service", "restart"]
    ]
  end

  defp config_paths(opts), do: NixSwarm.OperatorContext.paths(opts)

  defp maybe_put_default_target(opts, config_paths) do
    cond do
      Keyword.has_key?(opts, :target) ->
        opts

      env_target = present_env(System.get_env("NIX_SWARM_TARGET")) ->
        Keyword.put(opts, :target, env_target)

      config_target = ConfigFiles.default_target(config_paths) ->
        Keyword.put(opts, :target, config_target)

      true ->
        opts
    end
  end

  defp maybe_put_default_ssh_host(opts, config_paths) do
    if Keyword.has_key?(opts, :ssh_host) or is_nil(Keyword.get(opts, :target)) do
      opts
    else
      target = Keyword.get(opts, :target)

      try do
        case Enum.find(
               NixSwarm.Deploy.deployment_targets(config_paths.cluster_file),
               fn metadata ->
                 metadata.node == target
               end
             ) do
          %{host: host} -> Keyword.put(opts, :ssh_host, host)
          nil -> opts
        end
      rescue
        _error in [ArgumentError, RuntimeError] -> opts
      end
    end
  end

  defp present_env(nil), do: nil
  defp present_env(""), do: nil
  defp present_env(value), do: value

  defp connect_remote(opts) when is_list(opts) do
    try do
      target_node = opts |> NixSwarm.OperatorContext.remote() |> NixSwarm.Remote.connect!()
      {:ok, target_node}
    rescue
      e in [NixSwarm.Remote.Error, ArgumentError, RuntimeError] ->
        {:error, Exception.message(e)}
    end
  end

  defp deploy_options(opts, dry_run?) do
    opts
    |> Keyword.take([
      :source,
      :cluster_file,
      :machines_dir,
      :flake,
      :host,
      :hosts,
      :command_timeout_ms,
      :secret_file,
      :rotate_credentials
    ])
    |> Keyword.put(:dry_run, dry_run?)
  end

  defp require_confirmation!(opts, command) do
    unless Keyword.get(opts, :yes, false) do
      raise ArgumentError,
            "#{command} changes machines; inspect `nix-swarm cluster plan` first, then repeat with --yes"
    end
  end

  defp validate_service_name(overview, service_name) do
    known? =
      overview
      |> get_in([:status, :placements])
      |> Map.keys()
      |> Enum.any?(&(to_string(&1) == service_name))

    if known? do
      :ok
    else
      configured =
        overview
        |> get_in([:status, :placements])
        |> Map.keys()
        |> Enum.map_join(", ", &to_string/1)

      {:error,
       "unknown service #{inspect(service_name)}; configured services: #{configured || "none"}"}
    end
  end

  defp restart_units(overview, service_name) do
    deploy_hosts = get_in(overview, [:members, :deploy_hosts]) || %{}

    overview
    |> get_in([:status, :placements, service_name])
    |> List.wrap()
    |> Enum.sort_by(&Map.get(&1, :slot, 0))
    |> Enum.map(fn placement ->
      owner = Map.get(placement, :owner)

      %{
        unit: Map.fetch!(placement, :unit),
        owner: owner,
        slot: Map.get(placement, :slot),
        deploy_host: Map.get(deploy_hosts, owner) || Map.get(deploy_hosts, to_string(owner))
      }
    end)
  end

  defp run_command(command, args), do: System.cmd(command, args, stderr_to_stdout: true)

  defp print_json!(value), do: IO.puts(NixSwarm.JSON.encode!(value))

  defp print_service_logs(logs) do
    Enum.each(logs, fn {node, entries} ->
      IO.puts("=== #{node} ===")

      if is_list(entries) do
        Enum.each(entries, fn
          %{logs: log_text} -> IO.puts(log_text)
          other -> IO.inspect(other)
        end)
      else
        IO.puts(inspect(entries))
      end
    end)
  end

  defp print_cluster_status(overview) do
    members = overview.members
    status = overview.status

    IO.puts("Cluster status — #{members.queried_node}")
    IO.puts("")

    IO.puts(
      "Nodes (#{length(members.live_nodes)} live, #{length(members.configured_nodes)} configured):"
    )

    Enum.each(members.live_nodes, fn node ->
      node_status = Enum.find(status.nodes, fn {n, _} -> n == node end)
      version = if node_status, do: elem(node_status, 1)[:release_version] || "?", else: "?"
      IO.puts("  #{node}  #{version}")
    end)

    IO.puts("")
    IO.puts("Services:")

    Enum.each(status.placements, fn {svc, slots} ->
      owners = slots |> Enum.map(& &1.owner) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      IO.puts(
        "  #{svc}  #{length(slots)} replicas on #{Enum.map_join(owners, ", ", &Atom.to_string/1)}"
      )
    end)

    IO.puts("")
    diagnostics = Enum.filter(status.placement_diagnostics || [], &(&1.severity != :ok))

    if diagnostics != [] do
      IO.puts("Warnings/errors:")

      Enum.each(diagnostics, fn d ->
        IO.puts("  [#{d.severity}] #{d.message}")
      end)
    end
  end

  defp print_deploy_plan(plan) do
    if Map.has_key?(plan, :operator_plan) do
      IO.puts(NixSwarm.Deploy.Plan.render(plan.operator_plan))
    else
      IO.puts("NixOS deployment plan")
      IO.puts("  source: #{plan.source}")
      IO.puts("  rollout policy: sequential, one host at a time")
    end

    Enum.each(plan.validation.commands, &IO.puts("  validate: #{&1}"))

    plan.batches
    |> Enum.with_index(1)
    |> Enum.each(fn {batch, index} ->
      IO.puts("  batch #{index}:")
      Enum.each(batch, &IO.puts("    #{&1.rebuild_command}"))
    end)
  end

  defp print_deploy_result(result) do
    print_deploy_plan(result)
    IO.puts(if(result.dry_run, do: "Plan complete.", else: "Operation complete."))
  end

  defp legacy_command_error(args) do
    command = Enum.join(args, " ")
    launch = NixSwarm.operator_command()
    explicit_launch = NixSwarm.operator_launch()

    """
    Unknown command: `#{command}`.

      Nix-Swarm is code-first. Use a command below or launch the read-only console:
      #{launch}
      #{explicit_launch}

    The TUI only reads cluster state. Change the Nix configuration and use
    `nix-swarm cluster plan` followed by `nix-swarm cluster apply --yes`.
    """
    |> String.trim()
  end

  defp print_help do
    IO.puts("""
    Nix-Swarm

    Read-only operator TUI / console:
      #{NixSwarm.operator_command()}
      #{NixSwarm.operator_launch()}

    Deployment workflow:
      nix-swarm cluster plan --source /path/to/checkout
      nix-swarm cluster apply --source /path/to/checkout --yes
      nix-swarm cluster rollback --source /path/to/checkout --yes
      nix-swarm cluster upgrade --source /path/to/checkout --yes
      nix-swarm cluster credentials rotate --source /path/to/checkout --yes

    Read-only operations:
      nix-swarm cluster status --target NODE
      nix-swarm cluster doctor --target NODE
      nix-swarm service logs --name SERVICE --target NODE
      nix-swarm service restart --name SERVICE --target NODE --yes

    Targeted maintenance:
      --hosts HOSTS              comma-separated deliberate maintenance targets

    Remote connection:
      --target NODE              remote Nix-Swarm node
      --ssh-host USER@HOST       SSH destination

    Common options:
      --source PATH              local code-first Nix-Swarm flake root
      --cluster-file PATH        override the cluster file path
      --machines-dir PATH        override the machines directory
      --services-dir PATH        override the services directory
      --flake REF                local deployment flake (defaults to --source)
      --yes                      confirm a mutating operation
      --json                     structured output for status and logs

    Notes:
      - Nix code is the only desired-state mutation interface.
      - Inspect `cluster plan` before every mutating operation.
      - Operators never receive the BEAM cluster cookie.
    """)
  end
end
