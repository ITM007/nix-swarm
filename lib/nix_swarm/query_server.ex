defmodule NixSwarm.QueryServer do
  @moduledoc false

  use GenServer

  require Logger

  alias NixSwarm.QueryProtocol

  @default_socket "/run/nix-swarm/query.sock"
  @test_build Mix.env() == :test

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def socket_path do
    case Process.whereis(__MODULE__) do
      nil -> configured_socket_path()
      pid when pid == self() -> configured_socket_path()
      _pid -> GenServer.call(__MODULE__, :socket_path)
    end
  end

  defp configured_socket_path do
    Application.get_env(:nix_swarm, :query_socket) ||
      System.get_env("NIX_SWARM_QUERY_SOCKET") || test_socket_path() || @default_socket
  end

  defp test_socket_path do
    if @test_build do
      node = Node.self() |> Atom.to_string() |> String.replace(~r/[^A-Za-z0-9_.-]/, "-")
      Path.join(System.tmp_dir!(), "nix-swarm-query-#{node}.sock")
    end
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :socket_path, configured_socket_path())
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)

    listen_options = [
      :binary,
      active: false,
      packet: 4,
      packet_size: QueryProtocol.max_request_bytes(),
      reuseaddr: true,
      ifaddr: {:local, path}
    ]

    case :gen_tcp.listen(0, listen_options) do
      {:ok, listener} ->
        File.chmod!(path, 0o660)
        acceptor = spawn_link(fn -> accept_loop(listener) end)
        {:ok, %{listener: listener, acceptor: acceptor, path: path}}

      {:error, reason} ->
        {:stop, {:query_socket_failed, reason}}
    end
  end

  @impl true
  def handle_call(:socket_path, _from, state), do: {:reply, state.path, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    File.rm(state.path)
    :ok
  end

  defp accept_loop(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        hand_off(socket)

        accept_loop(listener)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:query_accept_failed, reason})
    end
  end

  defp hand_off(socket) do
    case Task.Supervisor.start_child(NixSwarm.TaskSupervisor, fn ->
           receive do
             {:serve, owned_socket} -> serve(owned_socket)
           after
             NixSwarm.rpc_timeout_ms() -> :ok
           end
         end) do
      {:ok, pid} ->
        case :gen_tcp.controlling_process(socket, pid) do
          :ok -> send(pid, {:serve, socket})
          {:error, _reason} -> :gen_tcp.close(socket)
        end

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp serve(socket) do
    response =
      with {:ok, payload} <- :gen_tcp.recv(socket, 0, NixSwarm.rpc_timeout_ms()),
           {:ok, request} <- QueryProtocol.decode_request(payload) do
        Logger.info("operator query", operation: operation_name(request))
        execute(request)
      else
        {:error, reason} -> {:error, reason}
      end

    binary = QueryProtocol.encode_local_response(response)

    if byte_size(binary) <= QueryProtocol.max_response_bytes() do
      :gen_tcp.send(socket, binary)
    else
      :gen_tcp.send(socket, QueryProtocol.encode_local_response({:error, :response_too_large}))
    end
  after
    :gen_tcp.close(socket)
  end

  defp execute(:cluster_overview), do: {:ok, NixSwarm.API.cluster_overview()}
  defp execute(:cluster_members), do: {:ok, NixSwarm.API.cluster_members()}

  defp execute({:operator_snapshot, service, nil, lines}) do
    {:ok, NixSwarm.API.operator_snapshot(service, nil, lines)}
  end

  defp execute({:operator_snapshot, service, node_name, lines}) do
    with {:ok, node} <- configured_node(node_name) do
      {:ok, NixSwarm.API.operator_snapshot(service, node, lines)}
    end
  end

  defp execute({:logs, service, lines}), do: {:ok, NixSwarm.API.logs(service, lines)}

  defp execute({:node_service_logs, node_name, lines}) do
    with {:ok, node} <- configured_node(node_name) do
      {:ok, NixSwarm.API.node_service_logs(node, lines)}
    end
  end

  defp execute({:cluster_logs, node_name, lines}) do
    with {:ok, node} <- configured_node(node_name) do
      {:ok, NixSwarm.API.cluster_logs(node, lines)}
    end
  end

  defp configured_node(node_name) do
    {:ok,
     NixSwarm.NodeName.resolve_existing!(
       node_name,
       NixSwarm.Config.peers(),
       "configured query node"
     )}
  rescue
    ArgumentError -> {:error, :unknown_node}
  end

  defp operation_name(operation) when is_atom(operation), do: operation
  defp operation_name({operation, _, _, _}), do: operation
  defp operation_name({operation, _, _}), do: operation
end
