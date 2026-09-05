defmodule NixSwarmWeb.QueryClientTest do
  use ExUnit.Case, async: false

  alias NixSwarmWeb.QueryClient
  alias NixSwarmWeb.QuerySocketStub

  defp json(value), do: value |> :json.encode() |> IO.iodata_to_binary()

  defp envelope(data) do
    json(%{"schema_version" => 1, "ok" => true, "data" => data})
  end

  defp remote_error(code) do
    json(%{
      "schema_version" => 1,
      "ok" => false,
      "error" => %{"code" => code}
    })
  end

  defp with_stub(response, fun, opts \\ []) do
    {:ok, pid, path} = QuerySocketStub.start(response, opts)

    on_exit(fn ->
      if Process.alive?(pid), do: QuerySocketStub.stop(pid)
      File.rm(path)
    end)

    fun.(socket_path: path)
  end

  test "queries cluster overview with the exact JSON profile payload" do
    with_stub(envelope(%{"nodes" => []}), fn opts ->
      assert {:ok, %{"nodes" => []}} = QueryClient.cluster_overview(opts)
      assert_receive {:query_socket_payload, "json-v1:cluster-overview"}
    end)
  end

  test "queries operator snapshot with encoded optional fields" do
    with_stub(envelope(%{"status" => "ok"}), fn opts ->
      assert {:ok, %{"status" => "ok"}} =
               QueryClient.operator_snapshot("web/api", "node@host", 200, opts)

      assert_receive {:query_socket_payload, payload}

      assert payload ==
               "json-v1:operator-snapshot:" <>
                 Base.url_encode64("web/api", padding: false) <>
                 ":" <>
                 Base.url_encode64("node@host", padding: false) <>
                 ":200"
    end)
  end

  test "queries service, node-service, and cluster logs" do
    with_stub(envelope(["line"]), fn opts ->
      assert {:ok, ["line"]} = QueryClient.logs("web", 10, opts)
      assert_receive {:query_socket_payload, "json-v1:logs:d2Vi:10"}
    end)

    with_stub(envelope(["line"]), fn opts ->
      assert {:ok, ["line"]} = QueryClient.node_service_logs("node@host", 10, opts)
      assert_receive {:query_socket_payload, "json-v1:node-service-logs:bm9kZUBob3N0:10"}
    end)

    with_stub(envelope(["line"]), fn opts ->
      assert {:ok, ["line"]} = QueryClient.cluster_logs("node@host", 10, opts)
      assert_receive {:query_socket_payload, "json-v1:cluster-logs:bm9kZUBob3N0:10"}
    end)
  end

  test "keeps JSON object keys as binaries" do
    with_stub(envelope(%{"outer" => %{"inner" => true}}), fn opts ->
      assert {:ok, %{"outer" => %{"inner" => true}}} = QueryClient.cluster_overview(opts)
    end)
  end

  test "returns a stable error for an agent error envelope" do
    with_stub(remote_error("unknown_node"), fn opts ->
      assert {:error, {:remote_error, "unknown_node"}} = QueryClient.cluster_overview(opts)
    end)
  end

  test "rejects invalid fields and line bounds before opening a socket" do
    no_socket = [socket_path: "/tmp/nix-swarm-web-no-such-socket.sock"]

    assert {:error, :invalid_service} = QueryClient.logs("", 10, no_socket)

    assert {:error, :invalid_node} =
             QueryClient.cluster_logs(String.duplicate("n", 256), 10, no_socket)

    assert {:error, :invalid_lines} = QueryClient.logs("web", 0, no_socket)
    assert {:error, :invalid_lines} = QueryClient.logs("web", 1_001, no_socket)
  end

  test "returns invalid_json for malformed JSON" do
    with_stub("not-json", fn opts ->
      assert {:error, :invalid_json} = QueryClient.cluster_overview(opts)
    end)
  end

  test "returns response_too_large when the JSON packet exceeds the configured bound" do
    response = String.duplicate("x", 256)

    with_stub(response, fn opts ->
      assert {:error, :response_too_large} =
               QueryClient.cluster_overview(Keyword.put(opts, :max_response_bytes, 128))
    end)
  end

  test "closes a server-closed socket with a stable error" do
    with_stub(
      envelope(%{}),
      fn opts ->
        assert {:error, :closed} = QueryClient.cluster_overview(opts)
      end,
      mode: :close
    )
  end

  test "returns receive_timeout when the server does not answer" do
    with_stub(
      envelope(%{}),
      fn opts ->
        assert {:error, :receive_timeout} =
                 QueryClient.cluster_overview(Keyword.put(opts, :receive_timeout, 10))
      end,
      mode: :timeout
    )
  end
end
