defmodule NixSwarmWeb.QueryRequest do
  @moduledoc "Builds the bounded JSON query-socket request payloads."

  @max_field_bytes 255
  @max_lines 1_000

  @type request ::
          :cluster_overview
          | {:operator_snapshot, binary() | nil, binary() | nil, pos_integer()}
          | {:logs, binary(), pos_integer()}
          | {:node_service_logs, binary(), pos_integer()}
          | {:cluster_logs, binary(), pos_integer()}

  @spec max_field_bytes() :: pos_integer()
  def max_field_bytes, do: @max_field_bytes

  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @spec encode(request()) :: {:ok, binary()} | {:error, atom()}
  def encode(:cluster_overview), do: {:ok, "json-v1:cluster-overview"}
  def encode(:cluster_members), do: {:ok, "json-v1:cluster-members"}
  def encode(:protocol_version), do: {:ok, "json-v1:protocol-version"}
  def encode(:capabilities), do: {:ok, "json-v1:capabilities"}

  def encode({:operator_snapshot, service, node, lines}) do
    with {:ok, service} <- optional_field(service, :invalid_service),
         {:ok, node} <- optional_field(node, :invalid_node),
         {:ok, lines} <- bounded_lines(lines) do
      {:ok, "json-v1:operator-snapshot:#{service}:#{node}:#{lines}"}
    end
  end

  def encode({:logs, service, lines}) do
    with {:ok, service} <- required_field(service, :invalid_service),
         {:ok, lines} <- bounded_lines(lines) do
      {:ok, "json-v1:logs:#{service}:#{lines}"}
    end
  end

  def encode({operation, node, lines}) when operation in [:node_service_logs, :cluster_logs] do
    with {:ok, node} <- required_field(node, :invalid_node),
         {:ok, lines} <- bounded_lines(lines) do
      operation_name =
        case operation do
          :node_service_logs -> "node-service-logs"
          :cluster_logs -> "cluster-logs"
        end

      {:ok, "json-v1:#{operation_name}:#{node}:#{lines}"}
    end
  end

  def encode(_request), do: {:error, :invalid_request}

  def encode_request(request), do: encode(request)

  defp bounded_lines(lines) when is_integer(lines) and lines in 1..@max_lines, do: {:ok, lines}
  defp bounded_lines(_lines), do: {:error, :invalid_lines}

  defp optional_field(nil, _error), do: {:ok, ""}
  defp optional_field(value, error), do: required_field(value, error)

  defp required_field(value, error) when is_binary(value) do
    if byte_size(value) in 1..@max_field_bytes do
      {:ok, Base.url_encode64(value, padding: false)}
    else
      {:error, error}
    end
  end

  defp required_field(_value, error), do: {:error, error}
end
