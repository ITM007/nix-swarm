defmodule NixSwarmQueryProtocolPhase4Test do
  use ExUnit.Case, async: true

  alias NixSwarm.QueryProtocol

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
end
