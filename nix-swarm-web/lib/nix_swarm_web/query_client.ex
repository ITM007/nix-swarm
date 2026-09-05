defmodule NixSwarmWeb.QueryClient do
  @moduledoc "Safe JSON client for the local Nix-Swarm query socket."

  alias NixSwarmWeb.QueryRequest

  @default_lines 200
  @default_connect_timeout 1_000
  @default_receive_timeout 2_000
  @default_max_response_bytes 4 * 1_024 * 1_024
  @max_socket_path_bytes 107

  @spec cluster_overview(keyword()) :: {:ok, term()} | {:error, term()}
  def cluster_overview(opts \\ []), do: query(:cluster_overview, opts)

  @spec encode_request(QueryRequest.request()) :: {:ok, binary()} | {:error, atom()}
  def encode_request(request), do: QueryRequest.encode(request)

  @spec operator_snapshot(binary(), binary() | nil) :: {:ok, term()} | {:error, term()}
  def operator_snapshot(service, node)
      when is_binary(service) and (is_binary(node) or is_nil(node)),
      do: operator_snapshot(service, node, @default_lines, [])

  @spec operator_snapshot(binary(), binary() | nil, keyword()) ::
          {:ok, term()} | {:error, term()}
  def operator_snapshot(service, node, opts)
      when is_binary(service) and (is_binary(node) or is_nil(node)) and is_list(opts) do
    operator_snapshot(service, node, @default_lines, opts)
  end

  @spec operator_snapshot(binary(), binary() | nil, pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def operator_snapshot(service, node, lines)
      when is_binary(service) and (is_binary(node) or is_nil(node)) and is_integer(lines),
      do: operator_snapshot(service, node, lines, [])

  @spec operator_snapshot(binary(), pos_integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def operator_snapshot(service, lines, opts) when is_binary(service) and is_integer(lines) do
    operator_snapshot(service, nil, lines, opts)
  end

  @spec operator_snapshot(binary(), binary() | nil, pos_integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def operator_snapshot(service, node, lines, opts)
      when is_binary(service) and (is_binary(node) or is_nil(node)) and is_integer(lines) do
    query({:operator_snapshot, service, node, lines}, opts)
  end

  @spec logs(binary()) :: {:ok, term()} | {:error, term()}
  def logs(service), do: logs(service, @default_lines, [])

  @spec logs(binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def logs(service, opts) when is_binary(service) and is_list(opts),
    do: logs(service, @default_lines, opts)

  @spec logs(binary(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def logs(service, lines) when is_binary(service) and is_integer(lines),
    do: logs(service, lines, [])

  @spec logs(binary(), pos_integer(), keyword()) :: {:ok, term()} | {:error, term()}
  def logs(service, lines, opts), do: query({:logs, service, lines}, opts)

  def service_logs(service), do: logs(service)
  def service_logs(service, value), do: logs(service, value)
  def service_logs(service, lines, opts), do: logs(service, lines, opts)

  @spec node_service_logs(binary()) :: {:ok, term()} | {:error, term()}
  def node_service_logs(node), do: node_service_logs(node, @default_lines, [])

  @spec node_service_logs(binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def node_service_logs(node, opts) when is_binary(node) and is_list(opts),
    do: node_service_logs(node, @default_lines, opts)

  @spec node_service_logs(binary(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def node_service_logs(node, lines) when is_binary(node) and is_integer(lines),
    do: node_service_logs(node, lines, [])

  @spec node_service_logs(binary(), pos_integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def node_service_logs(node, lines, opts),
    do: query({:node_service_logs, node, lines}, opts)

  @spec cluster_logs(binary()) :: {:ok, term()} | {:error, term()}
  def cluster_logs(node), do: cluster_logs(node, @default_lines, [])

  @spec cluster_logs(binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def cluster_logs(node, opts) when is_binary(node) and is_list(opts),
    do: cluster_logs(node, @default_lines, opts)

  @spec cluster_logs(binary(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def cluster_logs(node, lines) when is_binary(node) and is_integer(lines),
    do: cluster_logs(node, lines, [])

  @spec cluster_logs(binary(), pos_integer(), keyword()) :: {:ok, term()} | {:error, term()}
  def cluster_logs(node, lines, opts), do: query({:cluster_logs, node, lines}, opts)

  @spec query(QueryRequest.request(), keyword()) :: {:ok, term()} | {:error, term()}
  def query(request, opts \\ []) do
    with {:ok, payload} <- QueryRequest.encode(request),
         {:ok, socket_path} <- socket_path(opts),
         {:ok, connect_timeout} <-
           configured_timeout(opts, :connect_timeout, @default_connect_timeout),
         {:ok, receive_timeout} <-
           configured_timeout(opts, :receive_timeout, @default_receive_timeout),
         {:ok, max_response_bytes} <-
           response_limit(opts, :max_response_bytes, @default_max_response_bytes) do
      request(socket_path, payload, connect_timeout, receive_timeout, max_response_bytes)
    end
  end

  @spec decode_response(binary(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def decode_response(payload, max_response_bytes \\ @default_max_response_bytes)
      when is_binary(payload) and is_integer(max_response_bytes) do
    if byte_size(payload) > max_response_bytes do
      {:error, :response_too_large}
    else
      decode_envelope(payload)
    end
  end

  defp request(socket_path, payload, connect_timeout, receive_timeout, max_response_bytes) do
    connect_options = [
      :binary,
      active: false,
      packet: 4,
      packet_size: max_response_bytes,
      mode: :binary
    ]

    case :gen_tcp.connect({:local, socket_path}, 0, connect_options, connect_timeout) do
      {:ok, socket} ->
        try do
          with :ok <- send_request(socket, payload),
               {:ok, response} <- receive_response(socket, receive_timeout) do
            decode_response(response, max_response_bytes)
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, :timeout} ->
        {:error, :connect_timeout}

      {:error, :closed} ->
        {:error, :closed}

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  defp send_request(socket, payload) do
    case :gen_tcp.send(socket, payload) do
      :ok -> :ok
      {:error, :closed} -> {:error, :closed}
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  end

  defp receive_response(socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, response} -> {:ok, response}
      {:error, :timeout} -> {:error, :receive_timeout}
      {:error, :closed} -> {:error, :closed}
      {:error, :emsgsize} -> {:error, :response_too_large}
      {:error, reason} -> {:error, {:receive_failed, reason}}
    end
  end

  defp decode_envelope(payload) do
    case :json.decode(payload) do
      %{"schema_version" => 1, "ok" => true, "data" => data} ->
        {:ok, data}

      %{
        "schema_version" => 1,
        "ok" => false,
        "error" => %{"code" => code}
      }
      when is_binary(code) ->
        {:error, {:remote_error, code}}

      _ ->
        {:error, :invalid_response}
    end
  rescue
    _error -> {:error, :invalid_json}
  catch
    _kind, _reason -> {:error, :invalid_json}
  end

  defp socket_path(opts) do
    path = Keyword.get(opts, :socket_path, Application.get_env(:nix_swarm_web, :query_socket))

    cond do
      not is_binary(path) -> {:error, :invalid_socket_path}
      byte_size(path) not in 1..@max_socket_path_bytes -> {:error, :invalid_socket_path}
      not String.starts_with?(path, "/") -> {:error, :invalid_socket_path}
      String.contains?(path, <<0>>) -> {:error, :invalid_socket_path}
      true -> {:ok, path}
    end
  end

  defp configured_timeout(opts, key, default) do
    value = Keyword.get(opts, key, Keyword.get(opts, :timeout, default))

    if is_integer(value) and value in 1..60_000,
      do: {:ok, value},
      else: {:error, :invalid_timeout}
  end

  defp response_limit(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value in 1..@default_max_response_bytes,
      do: {:ok, value},
      else: {:error, :invalid_response_limit}
  end
end
