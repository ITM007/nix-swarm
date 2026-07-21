defmodule NixSwarm.Deploy do
  @moduledoc """
  Builds and applies NixOS configurations using Nix's native deployment path.

  The operator evaluates the local flake, then `nixos-rebuild` copies the
  resulting closure to each target. Nix-Swarm never writes a configuration
  checkout or generates machine files on a remote host.
  """

  alias NixSwarm.Paths

  @default_timeout_ms 30 * 60 * 1_000
  @default_health_timeout_sec 120
  @default_health_stable_samples 2
  @ssh_options [
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=10",
    "-o",
    "ServerAliveInterval=10",
    "-o",
    "ServerAliveCountMax=3",
    "-o",
    "StrictHostKeyChecking=yes"
  ]

  def defaults(source \\ nil) do
    resolved_source = source_root(source)
    machines_dir = default_machines_dir(resolved_source)

    %{
      source: resolved_source,
      flake: resolved_source,
      cluster_file: default_cluster_file(resolved_source),
      machines_dir: machines_dir,
      hosts: default_hosts(resolved_source, machines_dir),
      canary_hosts: [],
      max_unavailable: 1,
      build_host: nil,
      use_remote_sudo: true,
      command_timeout_ms: @default_timeout_ms
    }
  end

  def run(opts) do
    NixSwarm.Telemetry.span([:nix_swarm, :deploy], %{}, fn ->
      plan = opts |> normalize_opts() |> plan() |> validate!()

      if plan.dry_run do
        plan
      else
        results = run_batches!(plan)

        %{plan | results: results}
      end
    end)
  end

  @doc "Rolls target hosts back to their previous native NixOS system generation."
  def rollback(opts) do
    NixSwarm.Telemetry.span([:nix_swarm, :rollback], %{}, fn ->
      base = plan(opts)

      batches =
        Enum.map(base.batches, fn batch ->
          Enum.map(batch, fn target ->
            {executable, args, env} = rollback_invocation(target.host, opts)

            target
            |> Map.put(:executable, executable)
            |> Map.put(:args, args)
            |> Map.put(:env, env)
            |> Map.put(:rebuild_command, render_command(executable, args, env))
          end)
        end)

      rollback_plan = %{
        base
        | batches: batches,
          results: List.flatten(batches),
          validation: %{targets: [], commands: [], invocations: []}
      }

      if rollback_plan.dry_run do
        rollback_plan
      else
        results = run_batches!(rollback_plan)

        %{rollback_plan | results: results}
      end
    end)
  end

  def plan(opts) do
    opts = normalize_opts(opts)
    source = source_root(Keyword.get(opts, :source))
    cluster_file = Path.expand(Keyword.get(opts, :cluster_file, default_cluster_file(source)))
    machines_dir = Path.expand(Keyword.get(opts, :machines_dir, default_machines_dir(source)))
    flake = Keyword.get(opts, :flake, source)
    timeout_ms = positive_timeout!(Keyword.get(opts, :command_timeout_ms, @default_timeout_ms))
    validate_source_and_flake!(source, flake)
    manifest = deployment_manifest(flake, opts, timeout_ms)
    target_hosts = hosts_from_options(opts, manifest)
    canary_hosts = parse_hosts(Keyword.get(opts, :canary_hosts, []))
    max_unavailable = positive_rollout_width!(Keyword.get(opts, :max_unavailable, 1))
    target_hosts = order_hosts(target_hosts, canary_hosts)
    dry_run = Keyword.get(opts, :dry_run, false)
    health_check = Keyword.get(opts, :health_check, true) != false
    deployment_policy = manifest_value(manifest, "deployment") || %{}

    health_timeout_sec =
      positive_integer!(
        manifest_value(deployment_policy, "healthTimeoutSec") || @default_health_timeout_sec,
        "deployment health timeout"
      )

    health_stable_samples =
      positive_integer!(
        manifest_value(deployment_policy, "stableSamples") || @default_health_stable_samples,
        "deployment stable samples"
      )

    auto_rollback = manifest_value(deployment_policy, "autoRollback") != false

    if health_stable_samples > health_timeout_sec do
      raise ArgumentError,
            "deployment stable samples cannot exceed the health timeout in seconds"
    end

    validate_inputs!(source, target_hosts, flake)

    declared_configurations = deployment_configurations(manifest)

    explicit_configurations =
      normalize_configurations(Keyword.get(opts, :configurations, %{}))

    known_configurations = Map.merge(declared_configurations, explicit_configurations)

    configurations =
      Map.new(target_hosts, fn host ->
        case Map.fetch(known_configurations, host) do
          {:ok, configuration} ->
            {host, validate_configuration!(configuration)}

          :error ->
            raise ArgumentError,
                  "deployment host #{host} is missing from lib.nixSwarm.deploymentManifest"
        end
      end)

    results =
      Enum.map(target_hosts, fn host ->
        configuration = Map.fetch!(configurations, host)
        {executable, args, env} = rebuild_invocation(host, configuration, flake, opts)

        %{
          host: host,
          configuration: configuration,
          executable: executable,
          args: args,
          env: env,
          rebuild_command: render_command(executable, args, env)
        }
      end)

    canary_count = Enum.count(target_hosts, &(&1 in canary_hosts))

    batches =
      results
      |> Enum.split(canary_count)
      |> then(fn {canaries, remaining} ->
        Enum.map(canaries, &[&1]) ++ Enum.chunk_every(remaining, max_unavailable)
      end)

    validation_targets = configurations |> Map.values() |> Enum.uniq() |> Enum.sort()

    validation =
      Enum.map(validation_targets, fn configuration ->
        validation_invocation(flake, configuration)
      end)

    %{
      dry_run: dry_run,
      source: source,
      flake: flake,
      cluster_file: cluster_file,
      machines_dir: machines_dir,
      hosts: target_hosts,
      canary_hosts: Enum.filter(target_hosts, &(&1 in canary_hosts)),
      max_unavailable: max_unavailable,
      batches: batches,
      configurations: configurations,
      command_timeout_ms: timeout_ms,
      health_check: health_check,
      health_timeout_sec: health_timeout_sec,
      health_stable_samples: health_stable_samples,
      auto_rollback: auto_rollback,
      deployment_manifest: manifest,
      validation: %{
        targets: validation_targets,
        commands: Enum.map(validation, fn {exe, args, env} -> render_command(exe, args, env) end),
        invocations: validation
      },
      results: results
    }
  end

  def hosts(opts, source, machines_dir \\ nil) do
    opts = normalize_opts(opts)
    _machines_dir = machines_dir || default_machines_dir(source)

    case {Keyword.get(opts, :hosts), Keyword.get(opts, :host)} do
      {nil, nil} -> default_hosts(source)
      {nil, host} -> parse_hosts(host)
      {target_hosts, _host} -> parse_hosts(target_hosts)
    end
  end

  def default_hosts(source \\ nil, machines_dir \\ nil) do
    source = source_root(source)
    _machines_dir = machines_dir || default_machines_dir(source)

    source
    |> deployment_manifest([], @default_timeout_ms)
    |> deployment_targets_from_manifest()
    |> Enum.reject(&(&1.availability == "maintenance"))
    |> Enum.map(& &1.host)
  end

  @doc "Returns evaluated code-defined deployment targets for the flake containing a cluster module."
  def deployment_targets(cluster_file) do
    cluster_file
    |> Path.expand()
    |> flake_root!()
    |> deployment_manifest([], @default_timeout_ms)
    |> deployment_targets_from_manifest()
  end

  @doc "Evaluates the versioned deployment manifest exported by a cluster flake."
  def deployment_manifest(flake, opts \\ [], timeout_ms \\ @default_timeout_ms) do
    opts = normalize_opts(opts)

    case Keyword.get(opts, :deployment_manifest) do
      manifest when is_map(manifest) ->
        validate_manifest!(manifest)

      nil ->
        validate_flake_ref!(flake)
        installable = manifest_installable(flake)
        output = run_json_native!("nix", ["eval", "--json", installable], [], timeout_ms)

        case :json.decode(output) do
          manifest when is_map(manifest) -> validate_manifest!(manifest)
          _other -> raise ArgumentError, "deployment manifest must evaluate to an attribute set"
        end
    end
  rescue
    error in [ErlangError, ArgumentError] ->
      reraise error, __STACKTRACE__
  end

  defp validate_manifest!(manifest) do
    version = Map.get(manifest, "schemaVersion", Map.get(manifest, :schemaVersion))
    nodes = Map.get(manifest, "nodes", Map.get(manifest, :nodes))

    cond do
      version != 1 ->
        raise ArgumentError,
              "unsupported lib.nixSwarm.deploymentManifest schemaVersion: #{inspect(version)}"

      not is_map(nodes) or map_size(nodes) == 0 ->
        raise ArgumentError,
              "lib.nixSwarm.deploymentManifest.nodes must be a non-empty attribute set"

      true ->
        manifest
    end
  end

  defp manifest_installable(flake) do
    "#{deployment_flake_ref(flake)}#lib.nixSwarm.deploymentManifest"
  end

  defp deployment_flake_ref(flake) do
    if local_flake?(flake), do: "path:#{local_flake_path(flake)}", else: to_string(flake)
  end

  defp deployment_targets_from_manifest(manifest) do
    nodes = Map.get(manifest, "nodes", Map.get(manifest, :nodes, %{}))

    targets =
      nodes
      |> Enum.map(fn {node_name, metadata} ->
        node_name = to_string(node_name)
        deploy_host = manifest_value(metadata, "deployHost")
        configuration = manifest_value(metadata, "nixosConfiguration")
        availability = manifest_value(metadata, "availability") || "active"

        unless String.contains?(node_name, "@") do
          raise ArgumentError, "invalid deployment manifest node name: #{inspect(node_name)}"
        end

        unless availability in ["active", "draining", "maintenance"] do
          raise ArgumentError,
                "invalid availability for deployment manifest node #{node_name}: #{inspect(availability)}"
        end

        %{
          node: node_name,
          host: validate_ssh_host!(deploy_host),
          configuration: validate_configuration!(configuration),
          availability: to_string(availability)
        }
      end)
      |> Enum.sort_by(& &1.node)

    duplicate_hosts =
      targets
      |> Enum.frequencies_by(& &1.host)
      |> Enum.filter(fn {_host, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicate_hosts != [] do
      raise ArgumentError,
            "deployment manifest contains duplicate deploy hosts: #{Enum.join(duplicate_hosts, ", ")}"
    end

    targets
  end

  defp hosts_from_options(opts, manifest) do
    case {Keyword.get(opts, :hosts), Keyword.get(opts, :host)} do
      {nil, nil} ->
        manifest
        |> deployment_targets_from_manifest()
        |> Enum.reject(&(&1.availability == "maintenance"))
        |> Enum.map(& &1.host)

      {nil, host} ->
        parse_hosts(host)

      {target_hosts, _host} ->
        parse_hosts(target_hosts)
    end
  end

  defp manifest_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key, Map.get(metadata, String.to_atom(key)))
  end

  defp flake_root!(path) do
    path = if File.dir?(path), do: path, else: Path.dirname(path)
    candidate = Path.join(path, "flake.nix")
    parent = Path.dirname(path)

    cond do
      File.exists?(candidate) -> path
      parent == path -> raise ArgumentError, "no flake.nix found above #{path}"
      true -> flake_root!(parent)
    end
  end

  defp deployment_configurations(manifest) do
    manifest
    |> deployment_targets_from_manifest()
    |> Enum.reduce(%{}, fn
      %{host: host, configuration: configuration}, acc when is_binary(configuration) ->
        Map.put(acc, host, validate_configuration!(configuration))

      _target, acc ->
        acc
    end)
  end

  def machine_files(source) do
    source
    |> source_root()
    |> default_machines_dir()
    |> machine_files_from_dir()
  end

  def machine_files_from_dir(machines_dir) do
    machines_dir
    |> Path.expand()
    |> Path.join("*.nix")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @doc """
  Returns fail-closed Nix evaluation commands for machine configurations.

  This compatibility helper derives the configuration name from each machine
  filename. New code should use the validation data returned by `plan/1`.
  """
  def validation_commands(machine_files) do
    Enum.map(machine_files, fn machine_file ->
      source = machine_file |> Path.dirname() |> Path.dirname()
      configuration = machine_host(machine_file)
      {executable, args, env} = validation_invocation(source, configuration)
      render_command(executable, args, env)
    end)
  end

  @doc """
  Renders a local `nixos-rebuild` command.

  When `:target_host` is supplied the command uses Nix's native remote closure
  transport. This function is retained as a command-preview API.
  """
  def rebuild_command(opts, nixos_dir \\ "/etc/nixos") do
    opts = normalize_opts(opts)
    flake = Keyword.get(opts, :flake)

    args =
      ["switch"]
      |> maybe_append_option("--flake", flake)
      |> maybe_append_option(
        "-I",
        if(flake, do: nil, else: "nixos-config=#{Path.join(nixos_dir, "configuration.nix")}")
      )
      |> maybe_append_option("--target-host", Keyword.get(opts, :target_host))
      |> maybe_append_option("--build-host", Keyword.get(opts, :build_host))
      |> maybe_append_flag("--use-remote-sudo", Keyword.get(opts, :use_remote_sudo, false))

    render_command("nixos-rebuild", args, [])
  end

  @doc """
  Renders the native deployment command for a target host.

  `nixos_dir` is validated for compatibility but is not modified or copied.
  """
  def rebuild_host_command(host, nixos_dir, opts) do
    host = validate_ssh_host!(host)
    _nixos_dir = validate_absolute_path!(nixos_dir, "NixOS directory")
    opts = normalize_opts(opts)
    flake = Keyword.get(opts, :flake, Keyword.get(opts, :source, "."))
    configuration = configuration_for(host, Keyword.get(opts, :configurations, %{}))
    {executable, args, env} = rebuild_invocation(host, configuration, flake, opts)
    render_command(executable, args, env)
  end

  @doc deprecated: "Nix-Swarm no longer copies mutable source trees to remote hosts"
  def sync_command(_source, _host, _remote_path) do
    raise ArgumentError,
          "source synchronization was removed; deploy a flake with nixos-rebuild --target-host"
  end

  defp rebuild_invocation(host, configuration, flake, opts) do
    host = validate_ssh_host!(host)
    validate_flake_ref!(flake)

    args =
      [
        "switch",
        "--flake",
        "#{deployment_flake_ref(flake)}##{configuration}",
        "--target-host",
        host
      ]
      |> maybe_append_option("--build-host", Keyword.get(opts, :build_host))
      |> maybe_append_flag("--use-remote-sudo", Keyword.get(opts, :use_remote_sudo, true))

    {"nixos-rebuild", args, [{"NIX_SSHOPTS", Enum.join(@ssh_options, " ")}]}
  end

  defp rollback_invocation(host, opts) do
    opts = normalize_opts(opts)
    host = validate_ssh_host!(host)

    args =
      ["switch", "--rollback", "--target-host", host]
      |> maybe_append_option("--build-host", Keyword.get(opts, :build_host))
      |> maybe_append_flag("--use-remote-sudo", Keyword.get(opts, :use_remote_sudo, true))

    {"nixos-rebuild", args, [{"NIX_SSHOPTS", Enum.join(@ssh_options, " ")}]}
  end

  defp validation_invocation(flake, configuration) do
    validate_flake_ref!(flake)

    installable =
      "#{deployment_flake_ref(flake)}#nixosConfigurations.#{configuration}.config.system.build.toplevel"

    {"nix", ["build", "--no-link", installable], []}
  end

  defp validate!(plan) do
    Enum.each(plan.validation.invocations, fn {executable, args, env} ->
      run_native!(executable, args, env, plan.command_timeout_ms)
    end)

    plan
  end

  defp run_native!(executable, args, env, timeout_ms) do
    task =
      Task.Supervisor.async_nolink(NixSwarm.TaskSupervisor, fn ->
        System.cmd(executable, args, env: env, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        output

      {:ok, {output, status}} ->
        raise RuntimeError,
              "#{render_command(executable, args, env)} failed with status #{status}: #{String.trim(output)}"

      nil ->
        raise RuntimeError,
              "#{render_command(executable, args, env)} timed out after #{timeout_ms}ms"
    end
  rescue
    error in ErlangError ->
      raise RuntimeError,
            "could not execute #{executable}: #{Exception.message(error)}"
  end

  defp run_json_native!(executable, args, env, timeout_ms) do
    task =
      Task.Supervisor.async_nolink(NixSwarm.TaskSupervisor, fn ->
        System.cmd(executable, args, env: env)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        output

      {:ok, {_output, status}} ->
        raise RuntimeError,
              "#{render_command(executable, args, env)} failed with status #{status}"

      nil ->
        raise RuntimeError,
              "#{render_command(executable, args, env)} timed out after #{timeout_ms}ms"
    end
  rescue
    error in ErlangError ->
      raise RuntimeError, "could not execute #{executable}: #{Exception.message(error)}"
  end

  defp run_batch!(batch, timeout_ms) do
    Task.Supervisor.async_stream_nolink(
      NixSwarm.TaskSupervisor,
      batch,
      fn result ->
        output = run_native!(result.executable, result.args, result.env, timeout_ms)
        Map.put(result, :rebuild_output, output)
      end,
      max_concurrency: length(batch),
      ordered: true,
      timeout: timeout_ms + 1_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> raise RuntimeError, "deployment batch failed: #{inspect(reason)}"
    end)
  end

  defp run_batches!(plan) do
    do_run_batches!(plan.batches, plan, [], 0)
  end

  defp do_run_batches!([], _plan, results, _index), do: results

  defp do_run_batches!([batch | remaining], plan, results, index) do
    attempted = results ++ batch

    batch_results =
      try do
        batch_results = run_batch!(batch, plan.command_timeout_ms)

        if plan.health_check do
          verify_batch_health!(batch, remaining == [], plan)
        end

        batch_results
      rescue
        deployment_error ->
          rollback_result = maybe_rollback_attempted(attempted, plan)

          raise RuntimeError,
                "deployment failed in batch #{index + 1}: #{Exception.message(deployment_error)}; #{rollback_result}"
      end

    do_run_batches!(remaining, plan, results ++ batch_results, index + 1)
  end

  defp verify_batch_health!(batch, final_batch?, plan) do
    Enum.each(batch, fn target ->
      remote = %{
        target: target.configuration,
        ssh_host: target.host
      }

      wait_for_target_health!(
        remote,
        target.host,
        final_batch?,
        plan.health_timeout_sec,
        plan.health_stable_samples
      )
    end)
  end

  defp wait_for_target_health!(remote, host, final_batch?, timeout_sec, stable_samples) do
    attempts = max(timeout_sec, stable_samples)

    {result, consecutive} =
      Enum.reduce_while(1..attempts, {nil, 0}, fn attempt, {_last_error, consecutive} ->
        result = NixSwarm.Remote.query(remote, :cluster_overview)

        consecutive =
          if match?({:ok, overview} when is_map(overview), result) and
               healthy_overview?(elem(result, 1), final_batch?),
             do: consecutive + 1,
             else: 0

        cond do
          consecutive >= stable_samples ->
            {:halt, {:ok, consecutive}}

          attempt == attempts ->
            {:halt, {result, consecutive}}

          true ->
            Process.sleep(1_000)
            {:cont, {result, consecutive}}
        end
      end)

    if result != :ok do
      raise RuntimeError,
            "deployment health gate failed on #{host} after #{timeout_sec}s " <>
              "(#{consecutive}/#{stable_samples} stable samples): #{health_error(result)}"
    end
  end

  defp maybe_rollback_attempted(_attempted, %{auto_rollback: false}),
    do: "automatic rollback disabled by Nix policy"

  defp maybe_rollback_attempted(attempted, plan) do
    targets = Enum.uniq_by(attempted, & &1.host)

    rollback_batch =
      Enum.map(targets, fn target ->
        {executable, args, env} = rollback_invocation(target.host, Map.to_list(plan))
        %{target | executable: executable, args: args, env: env}
      end)

    try do
      _results = run_batch!(rollback_batch, plan.command_timeout_ms)
      "automatically rolled back #{length(rollback_batch)} attempted host(s)"
    rescue
      rollback_error ->
        "automatic rollback also failed: #{Exception.message(rollback_error)}"
    end
  end

  defp health_error({:ok, _overview}), do: "cluster did not converge"
  defp health_error({:error, reason}), do: inspect(reason)

  @doc false
  def healthy_overview?(overview, final_batch? \\ true)

  def healthy_overview?(%{members: members, status: status}, final_batch?) do
    live = Map.get(members, :live_nodes, []) |> MapSet.new()

    configured =
      Map.get(members, :required_nodes, Map.get(members, :configured_nodes, [])) |> MapSet.new()

    diagnostics_ok? =
      status
      |> Map.get(:placement_diagnostics, [])
      |> Enum.all?(fn diagnostic ->
        Map.get(diagnostic, :severity) != :error or
          (not final_batch? and Map.get(diagnostic, :reason) == :config_digest_mismatch)
      end)

    common_health =
      MapSet.subset?(configured, live) and diagnostics_ok? and nodes_reachable?(status) and
        queried_node_healthy?(status)

    if final_batch? do
      common_health and Map.get(status, :config_consistent?, false) and
        owned_units_healthy?(status)
    else
      common_health
    end
  end

  def healthy_overview?(_overview, _final_batch?), do: false

  defp nodes_reachable?(status) do
    status
    |> Map.get(:nodes, [])
    |> Enum.all?(fn {_node, node_status} -> not Map.has_key?(node_status, :error) end)
  end

  defp queried_node_healthy?(status) do
    queried_node = Map.get(status, :queried_node)

    with node when is_atom(node) <- queried_node,
         {_node, node_status} <-
           Enum.find(Map.get(status, :nodes, []), fn {candidate, _status} ->
             candidate == node
           end),
         false <- Map.has_key?(node_status, :error) do
      node_status
      |> Map.get(:services, [])
      |> Enum.all?(fn service ->
        units_healthy? =
          service
          |> Map.get(:units, [])
          |> Enum.filter(&(Map.get(&1, :owner) == node))
          |> Enum.all?(&(Map.get(&1, :status) == :running))

        units_healthy? and service_readiness_healthy?(service)
      end)
    else
      _ -> false
    end
  end

  defp owned_units_healthy?(status) do
    node_statuses = Map.new(Map.get(status, :nodes, []))

    status
    |> Map.get(:placements, %{})
    |> Enum.all?(fn {service_name, slots} ->
      Enum.all?(slots, fn slot ->
        with owner when is_atom(owner) <- Map.get(slot, :owner),
             %{services: services} <- Map.get(node_statuses, owner),
             %{units: units} = service <- Enum.find(services, &(&1.name == service_name)),
             true <- service_readiness_healthy?(service),
             %{status: unit_status} <- Enum.find(units, &(&1.unit == slot.unit)) do
          unit_status == :running
        else
          _ -> false
        end
      end)
    end)
  end

  defp service_readiness_healthy?(%{healthcheck: healthcheck}) when is_map(healthcheck),
    do: Map.get(healthcheck, :healthy, false)

  defp service_readiness_healthy?(_service), do: true

  defp configuration_for(host, configurations) do
    configurations = normalize_configurations(configurations)
    host = validate_ssh_host!(host)

    configured = Map.get(configurations, host)

    configuration =
      configured ||
        host
        |> strip_ssh_user()
        |> strip_ssh_port()
        |> String.split(".", parts: 2)
        |> hd()

    validate_configuration!(configuration)
  end

  defp normalize_configurations(configurations) when is_map(configurations) do
    Map.new(configurations, fn {host, configuration} ->
      {to_string(host), to_string(configuration)}
    end)
  end

  defp normalize_configurations(configurations) when is_list(configurations) do
    configurations |> Enum.into(%{}) |> normalize_configurations()
  end

  defp strip_ssh_user(host) do
    host |> String.split("@") |> List.last()
  end

  defp strip_ssh_port(host) do
    case Regex.run(~r/^(.+):(\d+)$/, host, capture: :all_but_first) do
      [hostname, _port] -> hostname
      nil -> host
    end
  end

  defp validate_configuration!(configuration) do
    configuration = to_string(configuration || "")

    if String.match?(configuration, ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/) do
      configuration
    else
      raise ArgumentError, "invalid NixOS configuration name: #{inspect(configuration)}"
    end
  end

  defp parse_hosts(value) do
    value
    |> List.wrap()
    |> case do
      [single] when is_binary(single) -> String.split(single, ",", trim: true)
      values -> values
    end
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&validate_ssh_host!/1)
    |> Enum.uniq()
  end

  defp source_root(nil), do: Paths.default_source()
  defp source_root(source), do: Path.expand(source)

  defp default_cluster_file(source) do
    candidates = [
      Path.join(source, "cluster.nix"),
      Path.join(source, "cluster/cluster.nix"),
      Path.join(source, "examples/config/cluster/cluster.nix")
    ]

    Enum.find(candidates, List.last(candidates), &File.exists?/1)
  end

  defp default_machines_dir(source) do
    candidates = [
      Path.join(source, "machines"),
      Path.join(source, "examples/config/machines")
    ]

    Enum.find(candidates, List.last(candidates), &(machine_files_from_dir(&1) != []))
  end

  defp validate_inputs!(source, target_hosts, flake) do
    cond do
      target_hosts == [] ->
        raise ArgumentError, "at least one host is required"

      not File.dir?(source) ->
        raise ArgumentError, "source directory does not exist: #{source}"

      local_flake?(flake) and not File.exists?(Path.join(local_flake_path(flake), "flake.nix")) ->
        raise ArgumentError, "flake.nix does not exist under #{local_flake_path(flake)}"

      true ->
        :ok
    end
  end

  defp validate_source_and_flake!(source, flake) do
    cond do
      not File.dir?(source) ->
        raise ArgumentError, "source directory does not exist: #{source}"

      local_flake?(flake) and not File.exists?(Path.join(local_flake_path(flake), "flake.nix")) ->
        raise ArgumentError, "flake.nix does not exist under #{local_flake_path(flake)}"

      true ->
        :ok
    end
  end

  defp validate_ssh_host!(host) do
    host = to_string(host)

    cond do
      String.trim(host) == "" ->
        raise ArgumentError, "SSH host cannot be blank"

      String.match?(host, ~r/[\x00-\x20]/) ->
        raise ArgumentError, "SSH host contains unsupported whitespace or control characters"

      String.starts_with?(host, "-") ->
        raise ArgumentError, "SSH host cannot start with a dash"

      not String.match?(host, ~r/^[A-Za-z0-9_.@:-]+$/) ->
        raise ArgumentError, "SSH host contains unsupported characters"

      true ->
        host
    end
  end

  defp validate_absolute_path!(path, label) do
    path = to_string(path)

    cond do
      Path.type(path) != :absolute ->
        raise ArgumentError, "#{label} must be an absolute path: #{path}"

      ".." in Path.split(path) ->
        raise ArgumentError, "#{label} must not contain '..': #{path}"

      true ->
        path
    end
  end

  defp validate_flake_ref!(flake) do
    flake = to_string(flake)

    if String.trim(flake) == "" or String.match?(flake, ~r/[\x00-\x20]/) do
      raise ArgumentError, "invalid flake reference: #{inspect(flake)}"
    end

    flake
  end

  defp local_flake?(flake) do
    flake = to_string(flake)
    Path.type(flake) == :absolute or String.starts_with?(flake, ".")
  end

  defp local_flake_path(flake) do
    flake |> to_string() |> String.split("#", parts: 2) |> hd() |> Path.expand()
  end

  defp positive_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp positive_timeout!(timeout),
    do: raise(ArgumentError, "invalid command timeout: #{inspect(timeout)}")

  defp positive_integer!(value, _label) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, label),
    do: raise(ArgumentError, "#{label} must be a positive integer, got: #{inspect(value)}")

  defp positive_rollout_width!(width) when is_integer(width) and width > 0, do: width

  defp positive_rollout_width!(width),
    do: raise(ArgumentError, "max_unavailable must be positive, got: #{inspect(width)}")

  defp order_hosts(hosts, canary_hosts) do
    canaries = Enum.filter(canary_hosts, &(&1 in hosts))
    canaries ++ Enum.reject(hosts, &(&1 in canaries))
  end

  defp machine_host(machine_file) do
    machine_file |> Path.basename() |> Path.rootname()
  end

  defp maybe_append_option(args, _flag, nil), do: args
  defp maybe_append_option(args, flag, value), do: args ++ [flag, to_string(value)]
  defp maybe_append_flag(args, _flag, false), do: args
  defp maybe_append_flag(args, flag, true), do: args ++ [flag]

  defp render_command(executable, args, []), do: shell_join([executable | args])

  defp render_command(executable, args, env) do
    env_prefix = Enum.map(env, fn {key, value} -> "#{key}=#{shell_escape(value)}" end)
    Enum.join(env_prefix ++ [shell_join([executable | args])], " ")
  end

  defp shell_join(values), do: Enum.map_join(values, " ", &shell_escape/1)
  defp shell_escape(value), do: "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Enum.to_list(opts)
end
