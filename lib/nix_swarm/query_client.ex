defmodule NixSwarm.QueryClient do
  @moduledoc false

  alias NixSwarm.QueryProtocol

  def query(request, opts \\ []) do
    path = Keyword.get(opts, :socket_path, NixSwarm.QueryServer.socket_path())
    timeout = Keyword.get(opts, :timeout, NixSwarm.rpc_timeout_ms())

    with {:ok, payload} <- QueryProtocol.encode_request(request),
         {:ok, socket} <-
           :gen_tcp.connect(
             {:local, path},
             0,
             [:binary, active: false, packet: 4, packet_size: QueryProtocol.max_response_bytes()],
             timeout
           ) do
      try do
        with :ok <- :gen_tcp.send(socket, payload),
             {:ok, binary} <- :gen_tcp.recv(socket, 0, timeout) do
          {:ok, :erlang.binary_to_term(binary, [:safe])}
        end
      after
        :gen_tcp.close(socket)
      end
    end
  rescue
    ArgumentError -> {:error, :invalid_response}
  end
end
