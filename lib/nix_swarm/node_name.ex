defmodule NixSwarm.NodeName do
  @moduledoc false

  @max_node_name_length 255
  @max_cookie_length 64
  @node_name_regex ~r/^[A-Za-z0-9][A-Za-z0-9_.-]*(?:@[A-Za-z0-9][A-Za-z0-9_.-]*)?$/
  @cookie_regex ~r/^[A-Za-z0-9_.-]+$/

  def to_node!(value, opts \\ [])

  def to_node!(value, _opts) when is_atom(value) do
    validate_node_name!(Atom.to_string(value))
    value
  end

  def to_node!(value, opts) do
    label = Keyword.get(opts, :label, "node name")
    node_name = validate_node_name!(value, label)
    candidates = Keyword.get(opts, :existing, [])

    case resolve_existing(node_name, candidates) do
      nil ->
        if Keyword.get(opts, :create, true) do
          String.to_atom(node_name)
        else
          raise ArgumentError, "unknown #{label}: #{node_name}"
        end

      node ->
        node
    end
  end

  def resolve_existing!(value, candidates, label \\ "node name") do
    to_node!(value, existing: candidates, create: false, label: label)
  end

  def control_node?(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> control_node?()
  end

  def control_node?(value) when is_binary(value) do
    value
    |> String.split("@", parts: 2)
    |> hd()
    |> String.starts_with?("nix-swarmctl-")
  end

  def control_node?(_value), do: false

  def cookie_atom!(value) do
    cookie = value |> to_string() |> String.trim()

    cond do
      cookie == "" ->
        raise ArgumentError, "cookie must not be blank"

      byte_size(cookie) > @max_cookie_length ->
        raise ArgumentError, "cookie is too long"

      not Regex.match?(@cookie_regex, cookie) ->
        raise ArgumentError, "cookie contains unsupported characters"

      true ->
        String.to_atom(cookie)
    end
  end

  defp validate_node_name!(value, label \\ "node name") do
    node_name = value |> to_string() |> String.trim()

    cond do
      node_name == "" ->
        raise ArgumentError, "#{label} must not be blank"

      byte_size(node_name) > @max_node_name_length ->
        raise ArgumentError, "#{label} is too long"

      not Regex.match?(@node_name_regex, node_name) ->
        raise ArgumentError, "#{label} contains unsupported characters"

      true ->
        node_name
    end
  end

  defp resolve_existing(_node_name, []), do: nil

  defp resolve_existing(node_name, candidates) do
    Enum.find_value(candidates, fn
      candidate when is_atom(candidate) ->
        if Atom.to_string(candidate) == node_name, do: candidate

      candidate when is_binary(candidate) ->
        if candidate == node_name, do: to_existing_atom(candidate)

      _candidate ->
        nil
    end)
  end

  defp to_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end
