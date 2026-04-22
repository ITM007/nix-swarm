defmodule Swarm.Service do
  @moduledoc false

  def normalize(raw) do
    name = fetch(raw, :name) |> to_string()
    replicas = fetch(raw, :replicas, 1) |> normalize_integer(1)

    %{
      name: name,
      replicas: replicas,
      unit_template: normalize_unit_template(fetch(raw, :unit_template) || fetch(raw, :unit)),
      constraints: fetch(raw, :constraints, []) |> normalize_labels(),
      healthcheck: fetch(raw, :healthcheck),
      settings: normalize_settings(fetch(raw, :settings, %{}))
    }
  end

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

  defp normalize_unit_template(nil), do: "%{service}@%{slot}.service"
  defp normalize_unit_template(template), do: to_string(template)

  defp normalize_labels(values) do
    values
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp normalize_settings(settings) when settings in [%{}, []], do: %{}
  defp normalize_settings(settings) when is_map(settings), do: settings
  defp normalize_settings(settings) when is_list(settings), do: Enum.into(settings, %{})
  defp normalize_settings(_settings), do: %{}

  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp normalize_integer(_value, default), do: default

  defp fetch(data, key, default \\ nil)

  defp fetch(data, key, default) when is_map(data),
    do: Map.get(data, key, Map.get(data, to_string(key), default))

  defp fetch(data, key, default) when is_list(data), do: Keyword.get(data, key, default)
end
