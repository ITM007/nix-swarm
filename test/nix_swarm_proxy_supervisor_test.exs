defmodule NixSwarm.ProxySupervisorTest do
  use ExUnit.Case, async: false

  @app :nix_swarm

  setup_all do
    _ = Application.stop(@app)
    System.put_env("NIX_SWARM_ROLE", "proxy")

    on_exit(fn ->
      _ = Application.stop(@app)
      System.delete_env("NIX_SWARM_ROLE")
      System.delete_env("NIX_SWARM_PROXY_CONFIG_PATH")
    end)

    :ok
  end

  setup do
    _ = Application.stop(@app)
    on_exit(fn -> _ = Application.stop(@app) end)
    :ok
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp write_config(terms) do
    path = Path.join(System.tmp_dir!(), "proxy-test-#{System.unique_integer([:positive])}.terms")

    :ok =
      path
      |> String.to_charlist()
      |> :file.open([:write])
      |> case do
        {:ok, io} ->
          :ok = :io.format(io, "~p.~n", [terms])
          :file.close(io)

        error ->
          raise "cannot write #{path}: #{inspect(error)}"
      end

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp http_get(port, path) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
      )

    response = recv_all(socket)
    :gen_tcp.close(socket)
    response
  end

  defp recv_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  test "role=proxy boots a listening endpoint and no operator children" do
    port = free_port()
    config_path = write_config(listen_port: port, routes: [])
    System.put_env("NIX_SWARM_PROXY_CONFIG_PATH", config_path)

    assert {:ok, _apps} = Application.ensure_all_started(@app)

    assert Process.whereis(NixSwarm.Proxy.Supervisor) != nil

    # operator children must NOT be started under the proxy role
    assert Process.whereis(NixSwarm.Cluster) == nil
    assert Process.whereis(NixSwarm.QueryServer) == nil
    assert Process.whereis(NixSwarm.Reconciler) == nil
    assert Process.whereis(NixSwarm.Watchdog) == nil

    # the endpoint answers on the configured port (stub 502 until routes land)
    response = http_get(port, "/")
    assert response =~ "HTTP/1.1 502"
  end

  test "role=proxy rejects a missing or invalid config at boot" do
    System.put_env("NIX_SWARM_PROXY_CONFIG_PATH", "/nonexistent/proxy.terms")

    assert {:error, _} = Application.ensure_all_started(@app)
  end
end
