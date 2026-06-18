defmodule NixSwarm.Service do
  @moduledoc false

  alias NixSwarm.NodeName

  def normalize(raw) do
    name = NixSwarm.fetch_value(raw, :name) |> to_string()
    replicas = NixSwarm.fetch_value(raw, :replicas, 1) |> normalize_integer(1)
    unit_template = normalize_unit_template(preferred_template(raw), replicas)

    %{
      name: name,
      replicas: replicas,
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
      healthcheck: normalize_optional(NixSwarm.fetch_value(raw, :healthcheck)),
      settings: normalize_settings(NixSwarm.fetch_value(raw, :settings, %{}))
    }
  end

  def default_unit_template(replicas) when replicas <= 1, do: "%{service}.service"
  def default_unit_template(_replicas), do: "%{service}@%{slot}.service"

  def slots(%{replicas: replicas}) when replicas <= 0, do: []
  def slots(%{replicas: replicas}), do: Enum.to_list(0..(replicas - 1))

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

  defp normalize_optional(value) when value in [nil, :undefined, "undefined"], do: nil
  defp normalize_optional(value), do: value

  defp normalize_node_name(name) when is_atom(name), do: name
  defp normalize_node_name(name), do: NodeName.to_node!(name, label: "preferred node name")
end
