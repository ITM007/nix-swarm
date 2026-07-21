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
    template: :string,
    force: :boolean,
    rotate_credentials: :boolean,
    lines: :integer,
    refresh_ms: :integer,
    source: :string,
    cluster_file: :string,
    machines_dir: :string,
    services_dir: :string,
    flake: :string,
    host: :string,
    hosts: :string,
    canary_hosts: :string,
    max_unavailable: :integer,
    command_timeout_ms: :integer,
    yes: :boolean,
    json: :boolean,
    replicas: :integer,
    constraints: :keep
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
        else: apply_launch_defaults(opts)

    plan_fun = Keyword.get(dependencies, :plan_fun, &NixSwarm.Deploy.run/1)
    deploy_fun = Keyword.get(dependencies, :deploy_fun, &NixSwarm.Deploy.run/1)
    rollback_fun = Keyword.get(dependencies, :rollback_fun, &NixSwarm.Deploy.rollback/1)
    ensure_fun = Keyword.get(dependencies, :ensure_fun, &NixSwarm.Cluster.Ensure.run/1)
    credentials_fun = Keyword.get(dependencies, :credentials_fun, &NixSwarm.Credentials.install/1)
    upgrade_fun = Keyword.get(dependencies, :upgrade_fun, &NixSwarm.Upgrade.run/2)

    cond do
      Keyword.get(opts, :version, false) ->
        IO.puts(NixSwarm.release_label())
        :ok

      Keyword.get(opts, :help, false) ->
        print_help()
        :ok

      args == ["cluster", "ensure"] ->
        require_confirmation!(opts, "cluster ensure")
        IO.puts("Ensuring cluster nodes are running nix-swarmd...\n")

        IO.puts(
          "After bootstrap, review the plan and apply future changes from the code checkout.\n"
        )

        result = ensure_fun.(deploy_options(opts, false))

        Enum.each(result.nodes, fn node ->
          case {node.status, node[:result]} do
            {:ok, :ok} ->
              IO.puts("  #{node.node}: #{node.action} (ok)")

            {:ok, {:error, reason}} ->
              IO.puts("  #{node.node}: ERROR - #{reason}")
              IO.puts(:stderr, "error: #{node.node}: #{reason}")

            {:ok, _result} ->
              IO.puts("  #{node.node}: #{node.action} (#{node[:message] || "ok"})")

            {:error, _} ->
              msg = node[:message] || "unknown error"
              IO.puts("  #{node.node}: ERROR - #{msg}")
              IO.puts(:stderr, "error: #{node.node}: #{msg}")
          end
        end)

        if result.ok, do: :ok, else: {:error, "some nodes failed; see above"}

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

      args == ["cluster", "credentials"] ->
        require_confirmation!(opts, "cluster credentials")
        result = credentials_fun.(deploy_options(opts, false))

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

      args == ["cluster", "init"] ->
        require_confirmation!(opts, "cluster init")
        IO.puts("Initializing nix-swarm cluster...\n")
        IO.puts("Installing the shared agent credential and activating all machines.\n")

        credential = credentials_fun.(deploy_options(opts, false))

        IO.puts(
          "  credential #{credential.fingerprint}: installed on #{length(credential.hosts)} host(s)"
        )

        result = ensure_fun.(deploy_options(opts, false))

        Enum.each(result.nodes, fn node ->
          case {node.status, node[:result]} do
            {:ok, :ok} ->
              IO.puts("  #{node.node}: #{node.action} (ok)")

            {:ok, {:error, reason}} ->
              IO.puts("  #{node.node}: ERROR - #{reason}")
              IO.puts(:stderr, "error: #{node.node}: #{reason}")

            {:ok, _result} ->
              IO.puts("  #{node.node}: #{node.action} (#{node[:message] || "ok"})")

            {:error, _} ->
              msg = node[:message] || "unknown error"
              IO.puts("  #{node.node}: ERROR - #{msg}")
              IO.puts(:stderr, "error: #{node.node}: #{msg}")
          end
        end)

        if result.ok do
          IO.puts(
            "\nNext: use `nix-swarm cluster doctor --target NODE` to verify read-only SSH access"
          )

          :ok
        else
          {:error, "some nodes failed; see above"}
        end

      args == ["service", "create"] ->
        name = Keyword.fetch!(opts, :name)
        template = Keyword.get(opts, :template, "web")
        paths = config_paths(opts)
        services_dir = paths.services_dir

        with :ok <- ConfigFiles.validate_generated_name(name, "service name"),
             {:ok, tpl} <- NixSwarm.Service.Templates.generate(template, String.trim(name)) do
          output = Path.expand(Path.join(services_dir, tpl.filename))
          services_root = Path.expand(services_dir) <> "/"

          if String.starts_with?(output, services_root) and not File.exists?(output) do
            output = Path.join(services_dir, tpl.filename)
            File.mkdir_p!(services_dir)
            File.write!(output, tpl.content, [:exclusive])
            IO.puts("Created #{output}")
            IO.puts("Service: #{name}")
            IO.puts("Template: #{template} — #{tpl.description}")
            IO.puts("Unit template: #{String.trim(name)}@%{slot}.service")
            IO.puts("Next: add the service and this unitTemplate to cluster.nix")
            :ok
          else
            {:error,
             "service file already exists or is outside the services directory: #{output}"}
          end
        else
          {:error, msg} -> {:error, msg}
        end

      args == ["service", "add"] ->
        name = Keyword.fetch!(opts, :name)
        template = Keyword.get(opts, :template, "web")
        replicas = Keyword.get(opts, :replicas, 1)
        constraints = Keyword.get(opts, :constraints, [])
        paths = config_paths(opts)

        with {:ok, tpl} <- NixSwarm.Service.Templates.generate(template, name),
             {:ok, output} <-
               NixSwarm.ConfigFiles.add_service(paths, name,
                 replicas: replicas,
                 constraints: constraints,
                 unit_template: "#{String.trim(name)}@%{slot}.service",
                 module_content: tpl.content
               ) do
          IO.puts("Created #{output}")
          IO.puts("Service: #{name}")
          IO.puts("Template: #{template} — #{tpl.description}")
          IO.puts("Next: import this module from #{paths.cluster_file}")
          :ok
        else
          {:error, msg} ->
            IO.puts(:stderr, msg)
            {:error, msg}
        end

      args == ["service", "list"] ->
        IO.puts("Available service templates:\n#{NixSwarm.Service.Templates.list()}")
        :ok

      args == ["service", "logs"] ->
        service_name = Keyword.fetch!(opts, :name)
        lines = Keyword.get(opts, :lines, 50)
        remote_opts = Keyword.take(opts, [:target, :ssh_host])

        with {:ok, target_node} <- connect_remote(remote_opts),
             logs <- NixSwarm.Remote.rpc!(target_node, NixSwarm.API, :logs, [service_name, lines]) do
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

          :ok
        else
          {:error, msg} ->
            IO.puts(:stderr, "error: #{msg}")
            {:error, msg}
        end

      args == ["cluster", "status"] ->
        remote_opts = Keyword.take(opts, [:target, :ssh_host])

        with {:ok, target_node} <- connect_remote(remote_opts),
             overview <- NixSwarm.Remote.rpc!(target_node, NixSwarm.API, :cluster_overview, []) do
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

          :ok
        else
          {:error, msg} ->
            IO.puts(:stderr, "error: #{msg}")
            {:error, msg}
        end

      args == ["debug", "state"] ->
        {:error, "debug state is intentionally unavailable through the read-only operator API"}

      args == ["cluster", "rebuild"] ->
        result =
          NixSwarm.Cluster.Rebuild.run(Keyword.take(opts, [:source, :cluster_file, :flake]))

        if result.ok, do: :ok, else: {:error, "some nodes failed; see above"}

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
    validate_integer_range!(opts, :max_unavailable, "--max-unavailable", 1, 128)
    validate_integer_range!(opts, :command_timeout_ms, "--command-timeout-ms", 1, 86_400_000)
    validate_integer_range!(opts, :replicas, "--replicas", 0, 128)
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

  defp config_paths(opts) do
    defaults = ConfigFiles.defaults(Keyword.get(opts, :source))

    ConfigFiles.normalize_paths(%{
      source: defaults.source,
      cluster_file: Keyword.get(opts, :cluster_file, defaults.cluster_file),
      machines_dir: Keyword.get(opts, :machines_dir, defaults.machines_dir),
      services_dir: Keyword.get(opts, :services_dir, defaults.services_dir)
    })
  end

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
      target_node = NixSwarm.Remote.connect!(opts)
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
      :canary_hosts,
      :max_unavailable,
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

  defp print_deploy_plan(plan) do
    IO.puts("NixOS deployment plan")
    IO.puts("  source: #{plan.source}")
    IO.puts("  rollout width: #{plan.max_unavailable}")

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
    launch = NixSwarm.operator_launch()

    IO.puts("""
    Nix-Swarm

    Inspect the cluster in the read-only operator TUI:
      #{NixSwarm.operator_command()}
      #{launch}
      #{launch} --source /path/to/checkout


    Bootstrap cluster nodes from cluster.nix:
      nix-swarm cluster init --source /path/to/flake --yes
      nix-swarm cluster credentials --source /path/to/flake --yes

    Preview and apply the Nix configuration:
      nix-swarm cluster plan --source /path/to/flake
      nix-swarm cluster apply --source /path/to/flake --yes
      nix-swarm cluster rollback --source /path/to/flake --yes
      nix-swarm cluster upgrade --source /path/to/flake --yes

    Read-only operations:
      nix-swarm cluster status --target NODE
      nix-swarm cluster doctor --target NODE
      nix-swarm service logs --name SERVICE --target NODE

    Remote target:
      --target NODE              remote Nix-Swarm node to connect to
                                 defaults to NIX_SWARM_TARGET or the first peer in cluster/cluster.nix

    Remote connection options:
      --ssh-host USER@HOST       SSH destination; defaults to the host in --target

    TUI options:
      --lines N                  default log line count (default: 50)
      --refresh-ms N             auto-refresh interval in milliseconds (default: 30000)
      --source PATH              local code-first Nix-Swarm flake root
      --cluster-file PATH        override the cluster file path
      --machines-dir PATH        override the machines directory
      --services-dir PATH        override the services directory
      --flake REF                local deployment flake (defaults to --source)
      --hosts HOSTS              comma-separated deployment targets
      --canary-hosts HOSTS       targets deployed first, one at a time
      --max-unavailable N        maximum parallel host changes (default: 1)
      --yes                      confirm apply or rollback

    Notes:
      - Run this from a Mix or release runtime with the ex_ratatui native library available.
      - Nix code is the only desired-state mutation interface; the TUI is read-only.
      - Without --source, Nix-Swarm prefers NIX_SWARM_SOURCE, then a local checkout/examples root, then ~/.config/nix-swarm.
      - Operators never receive the BEAM cluster cookie. Read operations use SSH and a restricted local Unix socket.
    """)
  end
end
