defmodule NixSwarmApiPhase4Test do
  use ExUnit.Case, async: false

  test "reports protocol capabilities and desired-versus-observed state" do
    capabilities = NixSwarm.API.capabilities()
    status = NixSwarm.API.desired_observed_state()

    assert capabilities.protocol_version == NixSwarm.QueryProtocol.protocol_version()
    assert :cluster_overview in capabilities.operations
    assert :operator_snapshot in capabilities.operations
    assert :logs in capabilities.operations
    assert :node_service_logs in capabilities.operations
    assert :cluster_logs in capabilities.operations
    assert is_map(status.desired)
    assert is_map(status.observed)
    assert Map.has_key?(status, :drift)
  end
end
