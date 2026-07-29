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
      unit_template: unit_template,
      allowed_nodes:
        NixSwarm.fetch_value(raw, :allowed_nodes, NixSwarm.fetch_value(raw, :allowedNodes, []))
        |> normalize_nodes(),
      autoscaling: autoscaling
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
      memory_target_percent:
        raw
        |> NixSwarm.fetch_value(
          :memory_target_percent,
          NixSwarm.fetch_value(raw, :memoryTargetPercent, 80)
        )
        |> normalize_integer(80)
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

  defp normalize_nodes(values) do
    values
    |> List.wrap()
    |> Enum.map(&normalize_node_name/1)
    |> Enum.uniq()
  end

  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp normalize_integer(_value, default), do: default

  defp normalize_optional(value) when value in [nil, :undefined, "undefined"], do: nil
  defp normalize_optional(value), do: value

  defp normalize_node_name(name) when is_atom(name), do: name
  defp normalize_node_name(name), do: NodeName.to_node!(name, label: "allowed node name")
end
