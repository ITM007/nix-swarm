defmodule NixSwarm.QueryProtocol do
  @moduledoc false

  @max_lines 1_000
  @max_request_bytes 8_192
  @max_response_bytes 4 * 1_024 * 1_024

  @type request ::
          :cluster_overview
          | :cluster_members
          | {:operator_snapshot, String.t() | nil, String.t() | nil, pos_integer()}
          | {:logs, String.t(), pos_integer()}
          | {:node_service_logs, String.t(), pos_integer()}
          | {:cluster_logs, String.t(), pos_integer()}

  def max_request_bytes, do: @max_request_bytes
  def max_response_bytes, do: @max_response_bytes

  def encode_request(:cluster_overview), do: {:ok, "cluster-overview"}
  def encode_request(:cluster_members), do: {:ok, "cluster-members"}

  def encode_request({:operator_snapshot, service, node, lines}) do
    with {:ok, lines} <- bounded_lines(lines),
         {:ok, service} <- optional_field(service),
         {:ok, node} <- optional_field(node) do
      {:ok, "operator-snapshot:#{service}:#{node}:#{lines}"}
    end
  end

  def encode_request({:logs, service, lines}) when is_binary(service) do
    with {:ok, lines} <- bounded_lines(lines),
         true <- byte_size(service) in 1..255 do
      {:ok, "logs:#{encode_field(service)}:#{lines}"}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def encode_request({operation, node, lines})
      when operation in [:node_service_logs, :cluster_logs] and (is_atom(node) or is_binary(node)) do
    with {:ok, lines} <- bounded_lines(lines) do
      operation =
        if operation == :node_service_logs, do: "node-service-logs", else: "cluster-logs"

      {:ok, "#{operation}:#{encode_field(to_string(node))}:#{lines}"}
    end
  end

  def encode_request(_request), do: {:error, :invalid_request}

  def decode_request(payload)
      when is_binary(payload) and byte_size(payload) <= @max_request_bytes do
    case String.split(payload, ":", parts: 4) do
      ["cluster-overview"] ->
        {:ok, :cluster_overview}

      ["cluster-members"] ->
        {:ok, :cluster_members}

      ["operator-snapshot", service, node, lines] ->
        with {:ok, service} <- decode_optional_field(service),
             {:ok, node} <- decode_optional_field(node),
             {:ok, lines} <- parse_lines(lines) do
          {:ok, {:operator_snapshot, service, node, lines}}
        else
          _ -> {:error, :invalid_request}
        end

      ["logs", service, lines] ->
        with {:ok, service} <- decode_field(service),
             true <- byte_size(service) in 1..255,
             {:ok, lines} <- parse_lines(lines) do
          {:ok, {:logs, service, lines}}
        else
          _ -> {:error, :invalid_request}
        end

      [operation, encoded_node, lines]
      when operation in ["node-service-logs", "cluster-logs"] ->
        with {:ok, node_name} <- decode_field(encoded_node),
             true <- byte_size(node_name) in 1..255,
             {:ok, lines} <- parse_lines(lines) do
          query = if operation == "node-service-logs", do: :node_service_logs, else: :cluster_logs
          {:ok, {query, node_name, lines}}
        else
          _ -> {:error, :invalid_request}
        end

      _ ->
        {:error, :unsupported_request}
    end
  end

  def decode_request(_payload), do: {:error, :request_too_large}

  def encode_response(response) do
    binary = :erlang.term_to_binary(response, [:deterministic])

    if byte_size(binary) <= @max_response_bytes do
      {:ok, Base.url_encode64(binary, padding: false)}
    else
      {:error, :response_too_large}
    end
  end

  def decode_response(encoded) when is_binary(encoded) do
    with {:ok, binary} <- Base.url_decode64(String.trim(encoded), padding: false),
         true <- byte_size(binary) <= @max_response_bytes do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    else
      _ -> {:error, :invalid_response}
    end
  rescue
    ArgumentError -> {:error, :invalid_response}
  end

  defp parse_lines(value) do
    case Integer.parse(value) do
      {lines, ""} -> bounded_lines(lines)
      _ -> {:error, :invalid_lines}
    end
  end

  defp bounded_lines(lines) when is_integer(lines) and lines in 1..@max_lines, do: {:ok, lines}
  defp bounded_lines(_lines), do: {:error, :invalid_lines}

  defp encode_field(value), do: Base.url_encode64(value, padding: false)
  defp decode_field(value), do: Base.url_decode64(value, padding: false)

  defp optional_field(nil), do: {:ok, ""}

  defp optional_field(value) when is_atom(value) or is_binary(value) do
    value = to_string(value)
    if byte_size(value) in 1..255, do: {:ok, encode_field(value)}, else: {:error, :invalid_field}
  end

  defp optional_field(_value), do: {:error, :invalid_field}

  defp decode_optional_field(""), do: {:ok, nil}

  defp decode_optional_field(value) do
    with {:ok, decoded} <- decode_field(value),
         true <- byte_size(decoded) in 1..255 do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_field}
    end
  end
end
