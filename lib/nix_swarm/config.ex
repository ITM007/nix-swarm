defmodule NixSwarm.Config do
  @moduledoc false

  alias NixSwarm.NodeName
  alias NixSwarm.Service

  @default_runtime %{
    connect_interval_ms: 500,
    reconcile_interval_ms: 5_000,
    autoscale_interval_ms: 10_000,
    failure_grace_ms: 10_000,
    recovery_stabilization_ms: 30_000,
    command_timeout_ms: 5_000,
    executor: %{adapter: :fake, root: Path.join(System.tmp_dir!(), "nix-swarm")},
    generation: "dev"
  }

  def current do
    case Application.get_env(:nix_swarm, :cluster_config) do
      nil -> server_snapshot() || load_current!()
      raw -> normalize(raw)
    end
  end

  def invalidate_cache do
    if Process.whereis(NixSwarm.Config.Server) do
      NixSwarm.Config.Server.reload()
    else
      :ok
    end
  end

  def digest do
    case Application.get_env(:nix_swarm, :cluster_config) do
      nil -> server_digest() || digest_for(current())
      raw -> raw |> normalize() |> digest_for()
    end
  end

  def load_current do
    path =
      Application.get_env(:nix_swarm, :config_path) || System.get_env("NIX_SWARM_CONFIG_PATH")

    case load_from_path(path) do
      {:ok, terms} -> {:ok, normalize(terms)}
      {:error, reason} -> {:error, reason}
      nil -> {:ok, normalize(%{})}
    end
  end

  def validate(config) do
    errors =
      []
      |> validate_runtime(config.runtime)
      |> validate_services(config.services)

    case Enum.reverse(errors) do
      [] -> :ok
      messages -> {:error, Enum.join(messages, "; ")}
    end
  end

  def digest_for(config) do
    config
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def peers do
    current().peers
  end

  def runtime do
    current().runtime
  end

  def load_from_path(nil), do: nil

  def load_from_path(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, terms} ->
        {:ok, terms |> normalize_terms()}

      {:error, reason} ->
        {:error, "failed to read nix-swarm config at #{path}: #{inspect(reason)}"}
    end
  end

  def normalize(raw) do
    nodes = normalize_nodes(NixSwarm.fetch_value(raw, :nodes, %{}))
    peers = normalize_peers(NixSwarm.fetch_value(raw, :peers, Map.keys(nodes)))
    runtime = normalize_runtime(NixSwarm.fetch_value(raw, :runtime, %{}))

    %{
      peers: peers,
      nodes: nodes,
      services: normalize_services(NixSwarm.fetch_value(raw, :services, [])),
      runtime: runtime,
      ingress: normalize_ingress(NixSwarm.fetch_value(raw, :ingress, []))
    }
  end

  defp normalize_terms([single]) when is_list(single), do: Enum.into(single, %{})
  defp normalize_terms(terms) when is_list(terms), do: Enum.into(terms, %{})

  defp normalize_services(raw_services) do
    raw_services
    |> List.wrap()
    |> Enum.map(&Service.normalize/1)
  end

  defp normalize_peers(raw_peers) do
    raw_peers
    |> List.wrap()
    |> Enum.map(&normalize_node_name/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_nodes(raw_nodes) when raw_nodes in [%{}, []], do: %{}

  defp normalize_nodes(raw_nodes) do
    raw_nodes
    |> Enum.into(%{}, fn {node_name, attrs} ->
      labels =
        attrs
        |> NixSwarm.fetch_value(:labels, [])
        |> List.wrap()
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      deploy_host =
        attrs
        |> NixSwarm.fetch_value(:deploy_host, NixSwarm.fetch_value(attrs, :deployHost))
        |> normalize_optional_string()

      nixos_configuration =
        attrs
        |> NixSwarm.fetch_value(
          :nixos_configuration,
          NixSwarm.fetch_value(attrs, :nixosConfiguration)
        )
        |> normalize_optional_string()

      {normalize_node_name(node_name),
       %{
         labels: labels,
         availability:
           normalize_availability(NixSwarm.fetch_value(attrs, :availability, :active)),
         deploy_host: deploy_host,
         nixos_configuration: nixos_configuration
       }}
    end)
  end

  defp normalize_runtime(raw_runtime) do
    executor = normalize_executor(NixSwarm.fetch_value(raw_runtime, :executor, %{}))

    @default_runtime
    |> Map.merge(%{
      connect_interval_ms:
        normalize_integer(
          NixSwarm.fetch_value(raw_runtime, :connect_interval_ms),
          @default_runtime.connect_interval_ms
        ),
      reconcile_interval_ms:
        normalize_integer(
          NixSwarm.fetch_value(raw_runtime, :reconcile_interval_ms),
          @default_runtime.reconcile_interval_ms
        ),
      autoscale_interval_ms:
        normalize_integer(
          NixSwarm.fetch_value(raw_runtime, :autoscale_interval_ms),
          @default_runtime.autoscale_interval_ms
        ),
      failure_grace_ms:
        normalize_integer(
          NixSwarm.fetch_value(raw_runtime, :failure_grace_ms),
          @default_runtime.failure_grace_ms
        ),
      recovery_stabilization_ms:
        normalize_integer(
          NixSwarm.fetch_value(raw_runtime, :recovery_stabilization_ms),
          @default_runtime.recovery_stabilization_ms
        ),
      command_timeout_ms:
        normalize_integer(
          NixSwarm.fetch_value(raw_runtime, :command_timeout_ms),
          @default_runtime.command_timeout_ms
        ),
      generation:
        to_string(NixSwarm.fetch_value(raw_runtime, :generation, @default_runtime.generation)),
      executor: executor
    })
  end

  defp normalize_executor(:systemd), do: %{adapter: :systemd}
  defp normalize_executor("systemd"), do: %{adapter: :systemd}

  defp normalize_executor(raw_executor) when is_map(raw_executor) or is_list(raw_executor) do
    adapter =
      case NixSwarm.fetch_value(raw_executor, :adapter, :fake) do
        value when value in [:systemd, "systemd"] -> :systemd
        _ -> :fake
      end

    case adapter do
      :systemd ->
        %{adapter: :systemd}

      :fake ->
        root =
          raw_executor
          |> NixSwarm.fetch_value(:root, @default_runtime.executor.root)
          |> to_string()

        %{adapter: :fake, root: root}
    end
  end

  defp normalize_executor(_), do: @default_runtime.executor

  defp normalize_integer(nil, default), do: default
  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp normalize_integer(_, default), do: default

  defp normalize_node_name(name) when is_atom(name), do: name
  defp normalize_node_name(name), do: NodeName.to_node!(name, label: "configured node name")

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp normalize_availability(value) when value in [:active, "active"], do: :active
  defp normalize_availability(value) when value in [:draining, "draining"], do: :draining
  defp normalize_availability(value) when value in [:maintenance, "maintenance"], do: :maintenance
  defp normalize_availability(_value), do: :active

  defp normalize_ingress(raw_sites) do
    %{
      sites:
        raw_sites
        |> List.wrap()
        |> Enum.reduce(%{}, fn site, acc ->
          name = NixSwarm.fetch_value(site, :name, "") |> to_string()

          next = %{
            domain: NixSwarm.fetch_value(site, :domain, name) |> to_string(),
            service: NixSwarm.fetch_value(site, :service, "") |> to_string(),
            ports:
              NixSwarm.fetch_value(site, :ports, [])
              |> List.wrap()
              |> Enum.map(&normalize_integer(&1, 0)),
            scheme: NixSwarm.fetch_value(site, :scheme, "http") |> to_string(),
            default: NixSwarm.fetch_value(site, :default, false) == true
          }

          if next.service != "" do
            Map.put(acc, name, next)
          else
            acc
          end
        end)
    }
  end

  defp load_current! do
    case load_current() do
      {:ok, config} -> config
      {:error, reason} -> raise RuntimeError, reason
    end
  end

  defp server_snapshot do
    case :ets.whereis(NixSwarm.Config.Server.table()) do
      :undefined -> nil
      _table -> lookup_snapshot(:config)
    end
  rescue
    ArgumentError -> nil
  end

  defp server_digest do
    case :ets.whereis(NixSwarm.Config.Server.table()) do
      :undefined -> nil
      _table -> lookup_snapshot(:digest)
    end
  rescue
    ArgumentError -> nil
  end

  defp lookup_snapshot(key) do
    case :ets.lookup(NixSwarm.Config.Server.table(), key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  defp validate_runtime(errors, runtime) do
    [
      :connect_interval_ms,
      :reconcile_interval_ms,
      :autoscale_interval_ms,
      :failure_grace_ms,
      :recovery_stabilization_ms,
      :command_timeout_ms
    ]
    |> Enum.reduce(errors, fn key, acc ->
      minimum = 100
      maximum = if key == :command_timeout_ms, do: 300_000, else: 3_600_000

      case Map.fetch!(runtime, key) do
        value when is_integer(value) and value >= minimum and value <= maximum ->
          acc

        value ->
          [
            "runtime.#{key} must be between #{minimum} and #{maximum}, got #{inspect(value)}"
            | acc
          ]
      end
    end)
  end

  defp validate_services(errors, services) do
    names = Enum.map(services, & &1.name)

    errors =
      names
      |> Enum.frequencies()
      |> Enum.reduce(errors, fn
        {name, count}, acc when count > 1 -> ["duplicate service name #{inspect(name)}" | acc]
        {_name, _count}, acc -> acc
      end)

    Enum.reduce(services, errors, fn service, acc ->
      acc
      |> maybe_error(service.name == "", "service names must not be empty")
      |> maybe_error(
        service.replicas < 0 or service.replicas > 128,
        "service #{service.name} replicas must be between 0 and 128"
      )
      |> maybe_error(
        Service.capacity_replicas(service) > 1 and
          not String.contains?(service.unit_template, "%{slot}"),
        "service #{service.name} unit template must contain %{slot} for multiple replicas"
      )
      |> maybe_error(
        Enum.any?(Service.slots(service, Service.capacity_replicas(service)), fn slot ->
          NixSwarm.Executor.validate_unit_name(Service.unit_name(service, slot)) != :ok
        end),
        "service #{service.name} renders an unsafe systemd unit name"
      )
      |> validate_service_limits(service)
    end)
  end

  defp validate_service_limits(errors, service) do
    autoscaling = service.autoscaling
    capacity = Service.capacity_replicas(service)

    errors
    |> maybe_error(
      service.max_replicas_per_node != nil and
        (service.max_replicas_per_node < 1 or service.max_replicas_per_node > 128),
      "service #{service.name} max_replicas_per_node must be between 1 and 128"
    )
    |> maybe_error(
      service.readiness.timeout_sec < 1 or service.readiness.timeout_sec > 3_600,
      "service #{service.name} readiness.timeout_sec must be between 1 and 3600"
    )
    |> maybe_error(
      service.readiness.stable_samples < 1 or service.readiness.stable_samples > 60,
      "service #{service.name} readiness.stable_samples must be between 1 and 60"
    )
    |> maybe_error(
      autoscaling.enabled and
        (autoscaling.min_replicas < 0 or autoscaling.min_replicas > service.replicas),
      "service #{service.name} autoscaling.min_replicas must be between 0 and replicas"
    )
    |> maybe_error(
      autoscaling.enabled and
        (autoscaling.max_replicas < service.replicas or autoscaling.max_replicas > 128),
      "service #{service.name} autoscaling.max_replicas must be between replicas and 128"
    )
    |> maybe_error(
      autoscaling.enabled and autoscaling.cpu_target_percent not in 1..100,
      "service #{service.name} autoscaling.cpu_target_percent must be between 1 and 100"
    )
    |> maybe_error(
      autoscaling.enabled and autoscaling.sample_window_sec not in 1..3_600,
      "service #{service.name} autoscaling.sample_window_sec must be between 1 and 3600"
    )
    |> maybe_error(
      autoscaling.enabled and autoscaling.scale_up_cooldown_sec not in 0..86_400,
      "service #{service.name} autoscaling.scale_up_cooldown_sec must be between 0 and 86400"
    )
    |> maybe_error(
      autoscaling.enabled and autoscaling.scale_down_cooldown_sec not in 0..86_400,
      "service #{service.name} autoscaling.scale_down_cooldown_sec must be between 0 and 86400"
    )
    |> maybe_error(
      autoscaling.enabled and autoscaling.max_step not in 1..128,
      "service #{service.name} autoscaling.max_step must be between 1 and 128"
    )
    |> maybe_error(
      capacity > 1 and not String.contains?(service.unit_template, "%{slot}"),
      "service #{service.name} autoscaling capacity requires a %{slot} unit template"
    )
  end

  defp maybe_error(errors, true, message), do: [message | errors]
  defp maybe_error(errors, false, _message), do: errors
end
