defmodule NixSwarmQueryProtocolPhase4Test do
  use ExUnit.Case, async: true

  alias NixSwarm.QueryProtocol
  alias NixSwarm.QueryCLI

  test "encodes and decodes protocol version and capabilities requests" do
    assert {:ok, "protocol-version"} = QueryProtocol.encode_request(:protocol_version)
    assert {:ok, :protocol_version} = QueryProtocol.decode_request("protocol-version")
    assert {:ok, "capabilities"} = QueryProtocol.encode_request(:capabilities)
    assert {:ok, :capabilities} = QueryProtocol.decode_request("capabilities")
  end

  test "capability responses are bounded and round-trip safely" do
    response = %{protocol_version: 2, release: "0.5.0", operations: [:cluster_overview]}
    assert {:ok, encoded} = QueryProtocol.encode_response(response)
    assert {:ok, ^response} = QueryProtocol.decode_response(encoded)
  end

  test "decodes atom-safe responses produced by another VM" do
    response = %{{:nix_swarm_atom, "wire_unknown_key_20260910"} => 1}

    encoded =
      response
      |> :erlang.term_to_binary([:deterministic])
      |> Base.url_encode64(padding: false)

    assert {:ok, %{"wire_unknown_key_20260910" => 1}} =
             QueryProtocol.decode_response(encoded)
  end

  test "query CLI unwraps the local success envelope before encoding" do
    response = %{queried_node: "swarm@node-a", live_nodes: ["swarm@node-a"]}

    assert QueryCLI.normalize_response({:ok, {:ok, response}}) == response
    assert QueryCLI.normalize_response({:ok, {:error, :busy}}) == {:error, :busy}
  end
end
