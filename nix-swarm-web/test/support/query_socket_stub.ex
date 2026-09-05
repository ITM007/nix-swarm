defmodule NixSwarmWeb.QuerySocketStub do
  @moduledoc false

  def start(response, opts \\ []) when is_binary(response) do
    path = Keyword.get(opts, :path, temporary_path())
    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: 4,
        ifaddr: {:local, path}
      ])

    pid =
      spawn_link(fn ->
        serve(listener, path, response, parent, Keyword.get(opts, :mode, :respond))
      end)

    {:ok, pid, path}
  end

  def stop(pid) when is_pid(pid) do
    Process.exit(pid, :normal)
  end

  defp serve(listener, path, response, parent, mode) do
    result = :gen_tcp.accept(listener)

    case result do
      {:ok, socket} ->
        case :gen_tcp.recv(socket, 0, 1_000) do
          {:ok, payload} -> send(parent, {:query_socket_payload, payload})
          {:error, reason} -> send(parent, {:query_socket_recv_error, reason})
        end

        case mode do
          :respond -> :gen_tcp.send(socket, response)
          :close -> :ok
          :timeout -> Process.sleep(2_000)
        end

        :gen_tcp.close(socket)

      {:error, reason} ->
        send(parent, {:query_socket_accept_error, reason})
    end

    :gen_tcp.close(listener)
    File.rm(path)
  end

  defp temporary_path do
    Path.join(System.tmp_dir!(), "nix-swarm-web-query-#{System.unique_integer([:positive])}.sock")
  end
end
