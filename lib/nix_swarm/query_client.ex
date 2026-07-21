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
          # This socket is local, permission-gated, and served by the agent on
          # the same machine. Agent responses contain configured Erlang node
          # atoms that are not necessarily loaded in the short-lived operator
          # helper, so the SSH-facing protocol remains safe-decoded while this
          # trusted local transport uses the original term representation.
          {:ok, :erlang.binary_to_term(binary)}
        end
      after
        :gen_tcp.close(socket)
      end
    end
  rescue
    ArgumentError -> {:error, :invalid_response}
  end
end
