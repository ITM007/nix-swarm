defmodule NixSwarm.Service do
  @moduledoc false

  alias NixSwarm.NodeName

  def normalize(raw) do
    name = NixSwarm.fetch_value(raw, :name) |> to_string()
    replicas = NixSwarm.fetch_value(raw, :replicas, 1) |> normalize_integer(1)
    autoscaling = normalize_autoscaling(NixSwarm.fetch_value(raw, :autoscaling, %{}), replicas)
    replica_capacity = if autoscaling.enabled, do: autoscaling.max_replicas, else: replicas
    unit_template = normalize_unit_template(preferred_template(raw), replica_capacity)

    %{
      name: name,
      replicas: replicas,
      max_replicas_per_node:
        raw
        |> NixSwarm.fetch_value(
          :max_replicas_per_node,
          NixSwarm.fetch_value(raw, :maxReplicasPerNode)
        )
        |> normalize_optional_integer(),
      unit_template: unit_template,
      constraints: NixSwarm.fetch_value(raw, :constraints, []) |> normalize_labels(),
      allowed_nodes:
        NixSwarm.fetch_value(raw, :allowed_nodes, NixSwarm.fetch_value(raw, :allowedNodes, []))
        |> normalize_nodes(),
      preferred_nodes:
        NixSwarm.fetch_value(
          raw,
          :preferred_nodes,
          NixSwarm.fetch_value(raw, :preferredNodes, [])
        )
        |> normalize_nodes(),
      readiness: normalize_readiness(NixSwarm.fetch_value(raw, :readiness, %{})),
      autoscaling: autoscaling,
      healthcheck: normalize_optional(NixSwarm.fetch_value(raw, :healthcheck)),
      settings: normalize_settings(NixSwarm.fetch_value(raw, :settings, %{}))
    }
  end

  def default_unit_template(replicas) when replicas <= 1, do: "%{service}.service"
  def default_unit_template(_replicas), do: "%{service}@%{slot}.service"

  def slots(service), do: slots(service, service.replicas)
  def slots(_service, replicas) when replicas <= 0, do: []
  def slots(_service, replicas), do: Enum.to_list(0..(replicas - 1))

  def capacity_replicas(%{autoscaling: %{enabled: true, max_replicas: replicas}}), do: replicas
  def capacity_replicas(service), do: service.replicas

  def unit_name(service, slot) do
    service.unit_template
    |> String.replace("@.service", "@#{slot}.service")
    |> String.replace("%{slot}", Integer.to_string(slot))
    |> String.replace("%{service}", service.name)
  end

  def eligible?(service, %{labels: labels}) do
    MapSet.subset?(MapSet.new(service.constraints), labels)
  end

  def eligible?(_service, _node_info), do: true

  defp normalize_readiness(raw) do
    %{
      mode: :systemd,
      timeout_sec:
        raw
        |> NixSwarm.fetch_value(:timeout_sec, NixSwarm.fetch_value(raw, :timeoutSec, 120))
        |> normalize_integer(120),
      stable_samples:
        raw
        |> NixSwarm.fetch_value(
          :stable_samples,
          NixSwarm.fetch_value(raw, :stableSamples, 2)
        )
        |> normalize_integer(2)
    }
  end

  defp normalize_autoscaling(raw, replicas) do
    enabled =
      NixSwarm.fetch_value(raw, :enable, NixSwarm.fetch_value(raw, :enabled, false)) == true

    %{
      enabled: enabled,
      min_replicas:
        raw
        |> NixSwarm.fetch_value(
          :min_replicas,
          NixSwarm.fetch_value(raw, :minReplicas, replicas)
        )
        |> normalize_integer(replicas),
      max_replicas:
        raw
        |> NixSwarm.fetch_value(
          :max_replicas,
          NixSwarm.fetch_value(raw, :maxReplicas, replicas)
        )
        |> normalize_integer(replicas),
      cpu_target_percent:
        raw
        |> NixSwarm.fetch_value(
          :cpu_target_percent,
          NixSwarm.fetch_value(raw, :cpuTargetPercent, 65)
        )
        |> normalize_integer(65),
      sample_window_sec:
        raw
        |> NixSwarm.fetch_value(
          :sample_window_sec,
          NixSwarm.fetch_value(raw, :sampleWindowSec, 60)
        )
        |> normalize_integer(60),
      scale_up_cooldown_sec:
        raw
        |> NixSwarm.fetch_value(
          :scale_up_cooldown_sec,
          NixSwarm.fetch_value(raw, :scaleUpCooldownSec, 30)
        )
        |> normalize_integer(30),
      scale_down_cooldown_sec:
        raw
        |> NixSwarm.fetch_value(
          :scale_down_cooldown_sec,
          NixSwarm.fetch_value(raw, :scaleDownCooldownSec, 300)
        )
        |> normalize_integer(300),
      max_step:
        raw
        |> NixSwarm.fetch_value(:max_step, NixSwarm.fetch_value(raw, :maxStep, 1))
        |> normalize_integer(1)
    }
  end

  defp preferred_template(raw) do
    case normalize_optional(NixSwarm.fetch_value(raw, :unit_template)) do
      nil -> normalize_optional(NixSwarm.fetch_value(raw, :unit))
      value -> value
    end
  end

  defp normalize_unit_template(nil, replicas), do: default_unit_template(replicas)
  defp normalize_unit_template(template, _replicas), do: to_string(template)

  defp normalize_labels(values) do
    values
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp normalize_nodes(values) do
    values
    |> List.wrap()
    |> Enum.map(&normalize_node_name/1)
    |> Enum.uniq()
  end

  defp normalize_settings(settings) when settings in [%{}, [], :undefined, "undefined"], do: %{}

  defp normalize_settings(settings) when is_map(settings) do
    Map.new(settings, fn {key, value} -> {key, normalize_setting_value(value)} end)
  end

  defp normalize_settings(settings) when is_list(settings) do
    if Keyword.keyword?(settings) do
      settings
      |> Enum.into(%{})
      |> normalize_settings()
    else
      %{}
    end
  end

  defp normalize_settings(_settings), do: %{}

  defp normalize_setting_value(value) when is_list(value) do
    cond do
      Keyword.keyword?(value) -> normalize_settings(value)
      List.ascii_printable?(value) -> to_string(value)
      true -> Enum.map(value, &normalize_setting_value/1)
    end
  end

  defp normalize_setting_value(value), do: value

  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp normalize_integer(_value, default), do: default

  defp normalize_optional_integer(value) when value in [nil, :undefined, "undefined"], do: nil
  defp normalize_optional_integer(value), do: normalize_integer(value, nil)

  defp normalize_optional(value) when value in [nil, :undefined, "undefined"], do: nil
  defp normalize_optional(value), do: value

  defp normalize_node_name(name) when is_atom(name), do: name
  defp normalize_node_name(name), do: NodeName.to_node!(name, label: "preferred node name")
end
