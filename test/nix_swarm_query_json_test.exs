defmodule NixSwarmQueryJSONTest do
  use ExUnit.Case, async: false

  alias NixSwarm.QueryProtocol

  @json_prefix "json-v1:"

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:nix_swarm)
    %{socket_path: :sys.get_state(NixSwarm.QueryServer).path}
  end

  test "wraps every allowlisted read in the additive JSON profile" do
    requests = [
      :protocol_version,
      :capabilities,
      :cluster_overview,
      :cluster_members,
      {:operator_snapshot, "api", Atom.to_string(Node.self()), 200},
      {:logs, "api", 200},
      {:node_service_logs, Atom.to_string(Node.self()), 200},
      {:cluster_logs, Atom.to_string(Node.self()), 200}
    ]

    for request <- requests do
      assert {:ok, payload} = QueryProtocol.encode_json_request(request)
      assert String.starts_with?(payload, @json_prefix)
      assert {:ok, {:json_v1, ^request}} = QueryProtocol.decode_request(payload)
    end
  end

  test "preserves existing ETF request encodings byte-for-byte" do
    requests = [
      {:protocol_version, "protocol-version"},
      {:capabilities, "capabilities"},
      {:cluster_overview, "cluster-overview"},
      {:cluster_members, "cluster-members"},
      {{:operator_snapshot, "api", Atom.to_string(Node.self()), 200},
       "operator-snapshot:YXBp:#{Base.url_encode64(Atom.to_string(Node.self()), padding: false)}:200"},
      {{:logs, "api", 200}, "logs:YXBp:200"},
      {{:node_service_logs, Atom.to_string(Node.self()), 200},
       "node-service-logs:#{Base.url_encode64(Atom.to_string(Node.self()), padding: false)}:200"},
      {{:cluster_logs, Atom.to_string(Node.self()), 200},
       "cluster-logs:#{Base.url_encode64(Atom.to_string(Node.self()), padding: false)}:200"}
    ]

    for {request, expected} <- requests do
      assert QueryProtocol.encode_request(request) == {:ok, expected}
    end
  end

  test "rejects nested, unknown, and mutating JSON operations" do
    assert {:error, :invalid_request} =
             QueryProtocol.encode_json_request({:json_v1, :cluster_members})

    for payload <- [
          "json-v1:",
          "json-v1:json-v1:cluster-members",
          "json-v1:{\"operation\":\"cluster_members\"}",
          "json-v1:reconcile"
        ] do
      assert {:error, :unsupported_request} = QueryProtocol.decode_request(payload)
    end

    assert {:error, :unsupported_request} = QueryProtocol.decode_request("reconcile")
  end

  test "keeps JSON request bounds at 8 KiB" do
    oversized = @json_prefix <> String.duplicate("x", QueryProtocol.max_request_bytes())

    assert byte_size(oversized) > QueryProtocol.max_request_bytes()
    assert {:error, :request_too_large} = QueryProtocol.decode_request(oversized)
  end

  test "encodes bounded JSON success and stable error envelopes" do
    assert {:ok, success} = QueryProtocol.encode_json_response({:ok, %{node: Node.self()}})

    assert :json.decode(success) == %{
             "schema_version" => 1,
             "ok" => true,
             "data" => %{"node" => Atom.to_string(Node.self())}
           }

    assert {:ok, error} = QueryProtocol.encode_json_response({:error, :unknown_node})

    assert :json.decode(error) == %{
             "schema_version" => 1,
             "ok" => false,
             "error" => %{"code" => "unknown_node"}
           }

    refute error =~ "unknown node"
    refute error =~ "stacktrace"
  end

  test "rejects JSON responses over 4 MiB" do
    response = {:ok, String.duplicate("x", QueryProtocol.max_response_bytes())}
    assert {:error, :response_too_large} = QueryProtocol.encode_json_response(response)
  end

  test "query server returns a JSON success envelope", %{socket_path: socket_path} do
    body = socket_request(socket_path, "json-v1:cluster-members")
    decoded = :json.decode(body)

    assert decoded["schema_version"] == 1
    assert decoded["ok"]
    assert is_map(decoded["data"])
    assert is_list(decoded["data"]["live_nodes"])
  end

  test "query server returns stable JSON errors for malformed requests", %{
    socket_path: socket_path
  } do
    body = socket_request(socket_path, "json-v1:reconcile")
    decoded = :json.decode(body)

    assert decoded == %{
             "schema_version" => 1,
             "ok" => false,
             "error" => %{"code" => "unsupported_request"}
           }
  end

  test "JSON node identifiers remain strings and resolve only configured nodes" do
    node = Atom.to_string(Node.self())
    encoded_node = Base.url_encode64(node, padding: false)

    assert {:ok, {:json_v1, {:cluster_logs, ^node, 10}}} =
             QueryProtocol.decode_request("json-v1:cluster-logs:#{encoded_node}:10")

    assert is_binary(node)
  end

  defp socket_request(path, payload) do
    {:ok, socket} =
      :gen_tcp.connect(
        {:local, path},
        0,
        [:binary, active: false, packet: 4, packet_size: QueryProtocol.max_response_bytes()],
        2_000
      )

    try do
      :ok = :gen_tcp.send(socket, payload)
      {:ok, response} = :gen_tcp.recv(socket, 0, 3_000)
      response
    after
      :gen_tcp.close(socket)
    end
  end
end
