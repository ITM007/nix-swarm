defmodule NixSwarm.ProxyTest.Upstream do
  @moduledoc false
  # Throwaway local upstream used by the forwarder tests.
  @behaviour Plug

  @big :binary.copy("A", 3_000_000)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn.request_path do
      "/ok" ->
        Plug.Conn.send_resp(conn, 200, "hello upstream")

      "/headers" ->
        body =
          Enum.map_join(conn.req_headers, "\n", fn {name, value} -> "#{name}=#{value}" end)

        Plug.Conn.send_resp(conn, 200, body)

      "/range" ->
        serve_range(conn)

      "/slow" ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "FIRST-HALF-")
        Process.sleep(800)
        {:ok, conn} = Plug.Conn.chunk(conn, "-LAST-HALF")
        Plug.Conn.halt(conn)

      _ ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp serve_range(conn) do
    case Plug.Conn.get_req_header(conn, "range") do
      ["bytes=" <> bounds] ->
        [first, last] = String.split(bounds, "-")
        first = String.to_integer(first)
        last = String.to_integer(last)
        slice = binary_part(@big, first, last - first + 1)

        conn
        |> Plug.Conn.put_resp_header("content-range", "bytes #{first}-#{last}/#{byte_size(@big)}")
        |> Plug.Conn.send_resp(206, slice)

      _ ->
        Plug.Conn.send_resp(conn, 200, @big)
    end
  end
end

defmodule NixSwarm.ProxyForwarderTest do
  use ExUnit.Case, async: false

  @pool :nix_swarm_proxy_pool

  setup_all do
    {:ok, pool_sup} =
      Supervisor.start_link([{ReverseIt, name: @pool, pool_size: 5}], strategy: :one_for_one)

    on_exit(fn ->
      if Process.alive?(pool_sup), do: Supervisor.stop(pool_sup)
    end)

    :ok
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp start_upstream do
    port = free_port()
    {:ok, _} = Bandit.start_link(plug: NixSwarm.ProxyTest.Upstream, port: port)
    port
  end

  defp start_proxy(port, routes) do
    config = NixSwarm.Proxy.Config.normalize(%{listen_port: port, routes: routes})
    :persistent_term.put({NixSwarm.Proxy, :config}, config)

    {:ok, _} =
      Bandit.start_link(
        plug: {NixSwarm.Proxy.Endpoint, []},
        port: port
      )

    port
  end

  defp http_request(port, host, path, headers \\ []) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)

    header_lines =
      Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: #{host}\r\n#{header_lines}Connection: close\r\n\r\n"
      )

    body = recv_all(socket)
    :gen_tcp.close(socket)
    body
  end

  defp recv_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 3_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp status_line(response), do: response |> String.split("\r\n") |> hd()

  defp body_of(response) do
    [_head, body] = String.split(response, "\r\n\r\n", parts: 2)

    if String.contains?(String.downcase(response), "transfer-encoding: chunked") do
      decode_chunks(body)
    else
      body
    end
  end

  defp decode_chunks(data, acc \\ "") do
    case Integer.parse(data, 16) do
      {0, _rest} ->
        acc

      {size, rest} ->
        rest = String.trim_leading(rest, "\r\n")
        <<chunk::binary-size(^size), "\r\n", tail::binary>> = rest
        decode_chunks(tail, acc <> chunk)
    end
  end

  defp recv_until(socket, marker, timeout, acc \\ "") do
    cond do
      String.contains?(acc, marker) ->
        acc

      timeout <= 0 ->
        acc

      true ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, data} -> recv_until(socket, marker, timeout, acc <> data)
          {:error, _} -> acc
        end
    end
  end

  test "forwards to a live single upstream and sets x-forwarded-* headers" do
    upstream = start_upstream()

    proxy =
      start_proxy(free_port(), [
        %{
          name: "web",
          host: "app.internal",
          path_prefix: "/",
          upstreams: ["127.0.0.1:#{upstream}"],
          auth: :public
        }
      ])

    response = http_request(proxy, "app.internal", "/ok")
    assert status_line(response) =~ "HTTP/1.1 200"
    assert body_of(response) == "hello upstream"

    response = http_request(proxy, "app.internal", "/headers")
    body = body_of(response)
    assert body =~ "x-forwarded-for="
    assert body =~ "x-forwarded-proto="
    assert body =~ "x-forwarded-host=app.internal"
  end

  test "byte-range requests pass through with the slice intact (206)" do
    upstream = start_upstream()

    proxy =
      start_proxy(free_port(), [
        %{
          name: "web",
          host: "media.internal",
          upstreams: ["127.0.0.1:#{upstream}"],
          auth: :public
        }
      ])

    response = http_request(proxy, "media.internal", "/range", [{"Range", "bytes=100-199"}])

    assert status_line(response) =~ "HTTP/1.1 206"
    assert String.downcase(response) =~ "content-range: bytes 100-199/3000000"
    assert body_of(response) == :binary.copy("A", 100)
  end

  test "large fixed bodies stream through uncorrupted" do
    upstream = start_upstream()

    proxy =
      start_proxy(free_port(), [
        %{
          name: "web",
          host: "media.internal",
          upstreams: ["127.0.0.1:#{upstream}"],
          auth: :public
        }
      ])

    response = http_request(proxy, "media.internal", "/range")
    assert status_line(response) =~ "HTTP/1.1 200"
    assert byte_size(body_of(response)) == 3_000_000
  end

  test "chunked responses arrive progressively, not buffered until the end" do
    upstream = start_upstream()

    proxy =
      start_proxy(free_port(), [
        %{name: "web", host: "slow.internal", upstreams: ["127.0.0.1:#{upstream}"], auth: :public}
      ])

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false], 2_000)

    :ok =
      :gen_tcp.send(
        socket,
        "GET /slow HTTP/1.1\r\nHost: slow.internal\r\nConnection: close\r\n\r\n"
      )

    started = System.monotonic_time(:millisecond)
    first = recv_until(socket, "FIRST-HALF-", 2_000)
    elapsed = System.monotonic_time(:millisecond) - started

    # The upstream sleeps 800ms before its second chunk; receiving the first
    # chunk well before that proves the proxy streams instead of buffering.
    assert first =~ "FIRST-HALF-"
    assert elapsed < 700

    rest = recv_all(socket)
    assert first <> rest =~ "-LAST-HALF"
  end

  test "a closed first upstream falls over to the next live one" do
    dead = free_port()
    live = start_upstream()

    proxy =
      start_proxy(free_port(), [
        %{
          name: "web",
          host: "app.internal",
          upstreams: ["127.0.0.1:#{dead}", "127.0.0.1:#{live}"],
          auth: :public
        }
      ])

    response = http_request(proxy, "app.internal", "/ok")
    assert status_line(response) =~ "HTTP/1.1 200"
    assert body_of(response) == "hello upstream"
  end

  test "all upstreams down yields 502" do
    dead = free_port()

    proxy =
      start_proxy(free_port(), [
        %{name: "web", host: "gone.internal", upstreams: ["127.0.0.1:#{dead}"], auth: :public}
      ])

    response = http_request(proxy, "gone.internal", "/ok")
    assert status_line(response) =~ "HTTP/1.1 502"
  end

  test "an unknown host yields 502" do
    upstream = start_upstream()

    proxy =
      start_proxy(free_port(), [
        %{name: "web", host: "app.internal", upstreams: ["127.0.0.1:#{upstream}"], auth: :public}
      ])

    response = http_request(proxy, "other.internal", "/ok")
    assert status_line(response) =~ "HTTP/1.1 502"
  end
end
