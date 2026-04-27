defmodule NixSwarmNodeNameTest do
  use ExUnit.Case, async: true

  test "resolve_existing! reuses existing node atoms" do
    candidate = :"nix-swarm@node-a.lan"

    assert NixSwarm.NodeName.resolve_existing!("nix-swarm@node-a.lan", [candidate]) == candidate
  end

  test "to_node! rejects unsupported node names" do
    assert_raise ArgumentError, ~r/unsupported characters/, fn ->
      NixSwarm.NodeName.to_node!("nix-swarm@node-a.lan;rm -rf /")
    end
  end

  test "cookie_atom! rejects unsafe cookie characters" do
    assert_raise ArgumentError, ~r/unsupported characters/, fn ->
      NixSwarm.NodeName.cookie_atom!("bad cookie")
    end
  end

  test "cookie_atom! accepts safe boundary values and rejects invalid lengths" do
    assert NixSwarm.NodeName.cookie_atom!("abc-DEF_123.cookie") == :"abc-DEF_123.cookie"
    assert NixSwarm.NodeName.cookie_atom!(String.duplicate("a", 64))

    assert_raise ArgumentError, ~r/too long/, fn ->
      NixSwarm.NodeName.cookie_atom!(String.duplicate("a", 65))
    end

    assert_raise ArgumentError, ~r/must not be blank/, fn ->
      NixSwarm.NodeName.cookie_atom!("")
    end
  end
end
