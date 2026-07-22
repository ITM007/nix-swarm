defmodule NixSwarm.JSON do
  @moduledoc false

  @doc "Encodes Nix-Swarm API terms as JSON without exposing Erlang atoms or keys."
  def encode(value) do
    value
    |> json_term()
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  def encode!(value), do: encode(value)

  defp json_term(nil), do: :null
  defp json_term(value) when is_boolean(value) or is_number(value) or is_binary(value), do: value
  defp json_term(:null), do: :null
  defp json_term(value) when is_atom(value), do: Atom.to_string(value)
  defp json_term(%MapSet{} = value), do: value |> MapSet.to_list() |> Enum.map(&json_term/1)
  defp json_term(value) when is_list(value), do: Enum.map(value, &json_term/1)

  defp json_term(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_term/1)

  defp json_term(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key_to_string(key), json_term(item)} end)
  end

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: inspect(key)
end
