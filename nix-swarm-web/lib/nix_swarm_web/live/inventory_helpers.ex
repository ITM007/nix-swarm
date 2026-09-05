defmodule NixSwarmWeb.InventoryHelpers do
  @moduledoc false

  def encode_identifier(value), do: Base.url_encode64(to_string(value), padding: false)

  def decode_identifier(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> decoded
      :error -> value
    end
  end

  def decode_identifier(value), do: to_string(value)

  def bounded_lines(value, default \\ 200)
  def bounded_lines(value, _default) when is_integer(value) and value in 1..1_000, do: value

  def bounded_lines(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {lines, ""} when lines in 1..1_000 -> lines
      _ -> default
    end
  end

  def bounded_lines(_value, default), do: default

  def metric_label(value, kind \\ :number)
  def metric_label(nil, _kind), do: "Unknown"
  def metric_label(%{status: "unknown"}, _kind), do: "Unknown"
  def metric_label(value, :percent) when is_number(value), do: "#{value}%"
  def metric_label(value, :bytes) when is_number(value), do: "#{value} bytes"
  def metric_label(value, _kind) when is_number(value), do: to_string(value)
  def metric_label(value, _kind), do: to_string(value)

  def map_value(map, key, default \\ nil)

  def map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  def map_value(_map, _key, default), do: default

  def state_label(value) when value in [nil, "", "unknown"], do: "Unknown"

  def state_label(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  def error_text(error) when is_map(error) do
    scope = map_value(error, :scope, "query")
    reason = map_value(error, :reason, "unknown")
    "#{scope}: #{reason}"
  end

  def error_text(error), do: to_string(error)
end
