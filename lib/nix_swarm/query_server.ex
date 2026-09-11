defmodule NixSwarm.QueryServer do
  @moduledoc false

  use GenServer

  import Bitwise
  require Logger

  alias NixSwarm.QueryProtocol

  @default_socket "/run/nix-swarm/query.sock"
  @response_reserve_ms 10
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
    task_supervisor = Keyword.get(opts, :task_supervisor, NixSwarm.QueryTaskSupervisor)

    request_timeout_ms =
      bounded_timeout(Keyword.get(opts, :request_timeout_ms, NixSwarm.rpc_timeout_ms()))

    execute_fun = Keyword.get(opts, :execute_fun, &execute/1)

    File.mkdir_p!(Path.dirname(path))

    listen_options = [
      :binary,
      active: false,
      packet: 4,
      packet_size: QueryProtocol.max_request_bytes(),
      send_timeout: request_timeout_ms,
      send_timeout_close: true,
      reuseaddr: true,
      ifaddr: {:local, path}
    ]

    with :ok <- prepare_socket_path(path),
         {:ok, listener} <- :gen_tcp.listen(0, listen_options),
         {:ok, %{inode: inode}} <- File.stat(path) do
      File.chmod!(path, 0o660)

      acceptor =
        spawn_link(fn ->
          accept_loop(listener, task_supervisor, request_timeout_ms, execute_fun)
        end)

      {:ok,
       %{
         listener: listener,
         acceptor: acceptor,
         path: path,
         inode: inode,
         task_supervisor: task_supervisor,
         request_timeout_ms: request_timeout_ms,
         execute_fun: execute_fun
       }}
    else
      {:error, reason} ->
        {:stop, {:query_socket_failed, reason}}
    end
  end

  @impl true
  def handle_call(:socket_path, _from, state), do: {:reply, state.path, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    remove_owned_socket(state.path, state.inode)
    :ok
  end

  defp prepare_socket_path(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, metadata} ->
        if socket_file?(metadata),
          do: File.rm(path),
          else: {:error, {:socket_path_occupied, path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_owned_socket(path, inode) do
    case File.stat(path) do
      {:ok, %{inode: ^inode} = metadata} ->
        if socket_file?(metadata), do: File.rm(path), else: :ok

      _ ->
        :ok
    end
  end

  defp socket_file?(%{mode: mode}), do: band(mode, 0o170_000) == 0o140_000

  defp accept_loop(listener, task_supervisor, request_timeout_ms, execute_fun) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        hand_off(socket, task_supervisor, request_timeout_ms, execute_fun)

        accept_loop(listener, task_supervisor, request_timeout_ms, execute_fun)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:query_accept_failed, reason})
    end
  end

  defp hand_off(socket, task_supervisor, request_timeout_ms, execute_fun) do
    case Task.Supervisor.start_child(task_supervisor, fn ->
           receive do
             {:serve, owned_socket} ->
               serve(owned_socket, task_supervisor, request_timeout_ms, execute_fun)
           after
             request_timeout_ms -> :ok
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

  defp serve(socket, task_supervisor, request_timeout_ms, execute_fun) do
    deadline = System.monotonic_time(:millisecond) + request_timeout_ms

    {profile, response} =
      case :gen_tcp.recv(socket, 0, remaining_ms(deadline)) do
        {:ok, payload} ->
          profile = if QueryProtocol.json_request?(payload), do: :json_v1, else: :etf

          response =
            case QueryProtocol.decode_request(payload) do
              {:ok, request} ->
                Logger.info("operator query", operation: operation_name(request))
                execute_with_deadline(request, deadline, task_supervisor, execute_fun)

              {:error, reason} ->
                {:error, reason}
            end

          {profile, response}

        {:error, reason} ->
          {:etf, {:error, reason}}
      end

    send_response(socket, profile, response, deadline)
  after
    :gen_tcp.close(socket)
  end

  defp send_response(socket, :json_v1, response, deadline) do
    case QueryProtocol.encode_json_response(response) do
      {:ok, binary} ->
        send_with_deadline(socket, binary, deadline)

      {:error, :response_too_large} ->
        {:ok, binary} = QueryProtocol.encode_json_response({:error, :response_too_large})
        send_with_deadline(socket, binary, deadline)

      {:error, _reason} ->
        {:ok, binary} = QueryProtocol.encode_json_response({:error, :internal_error})
        send_with_deadline(socket, binary, deadline)
    end
  end

  defp send_response(socket, :etf, response, deadline) do
    binary = QueryProtocol.encode_local_response(response)

    if byte_size(binary) <= QueryProtocol.max_response_bytes() do
      send_with_deadline(socket, binary, deadline)
    else
      send_with_deadline(
        socket,
        QueryProtocol.encode_local_response({:error, :response_too_large}),
        deadline
      )
    end
  end

  defp execute_with_deadline(request, deadline, task_supervisor, execute_fun) do
    execution_budget = max(remaining_ms(deadline) - @response_reserve_ms, 0)

    if execution_budget == 0 do
      {:error, :timeout}
    else
      task = Task.Supervisor.async_nolink(task_supervisor, fn -> execute_fun.(request) end)

      case Task.yield(task, execution_budget) || Task.shutdown(task, :brutal_kill) do
        {:ok, response} -> response
        {:exit, reason} -> {:error, reason}
        nil -> {:error, :timeout}
      end
    end
  catch
    :exit, _reason -> {:error, :busy}
  end

  defp send_with_deadline(socket, binary, deadline) do
    case remaining_ms(deadline) do
      0 ->
        {:error, :timeout}

      timeout ->
        :inet.setopts(socket, send_timeout: timeout, send_timeout_close: true)
        :gen_tcp.send(socket, binary)
    end
  end

  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp bounded_timeout(value) when is_integer(value) and value > 0, do: min(value, 60_000)
  defp bounded_timeout(_value), do: NixSwarm.rpc_timeout_ms()

  defp execute(:protocol_version), do: {:ok, NixSwarm.QueryProtocol.protocol_version()}
  defp execute(:capabilities), do: {:ok, NixSwarm.API.capabilities()}
  defp execute(:cluster_overview), do: {:ok, NixSwarm.API.cluster_overview()}
  defp execute(:cluster_members), do: {:ok, NixSwarm.API.cluster_members()}
  defp execute({:json_v1, request}), do: execute(request)

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
  defp operation_name({:json_v1, request}), do: operation_name(request)
  defp operation_name({operation, _, _, _}), do: operation
  defp operation_name({operation, _, _}), do: operation
end
