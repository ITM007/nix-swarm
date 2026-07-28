defmodule NixSwarmJSONTest do
  use ExUnit.Case, async: true

  test "encodes API terms with JSON-safe string keys and values" do
    encoded =
      NixSwarm.JSON.encode!(%{
        node: :"nix-swarm@node-a",
        enabled: true,
        members: MapSet.new([:"nix-swarm@node-a"]),
        placement: {1, nil}
      })

    decoded = :json.decode(encoded)
    assert decoded["node"] == "nix-swarm@node-a"
    assert decoded["enabled"]
    assert decoded["members"] == ["nix-swarm@node-a"]
    assert decoded["placement"] == [1, :null]
  end
end
