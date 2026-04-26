defmodule SwarmNodeNameTest do
  use ExUnit.Case, async: true

  test "resolve_existing! reuses existing node atoms" do
    candidate = :"swarm@node-a.lan"

    assert Swarm.NodeName.resolve_existing!("swarm@node-a.lan", [candidate]) == candidate
  end

  test "to_node! rejects unsupported node names" do
    assert_raise ArgumentError, ~r/unsupported characters/, fn ->
      Swarm.NodeName.to_node!("swarm@node-a.lan;rm -rf /")
    end
  end

  test "cookie_atom! rejects unsafe cookie characters" do
    assert_raise ArgumentError, ~r/unsupported characters/, fn ->
      Swarm.NodeName.cookie_atom!("bad cookie")
    end
  end
end
