defmodule NixSwarmServiceTemplatesTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Service.Templates

  test "lists every supported template" do
    listing = Templates.list()

    for name <- ["web", "custom"] do
      assert listing =~ "#{name}:"
    end

    refute listing =~ "postgres:"
  end

  test "generates named NixOS modules for every template" do
    for name <- ["web", "custom"] do
      assert {:ok, generated} = Templates.generate(name, "my-service")
      assert generated.filename == "my-service.nix"
      refute generated.content =~ "{name}"
      assert is_binary(generated.description)
    end
  end

  test "returns a useful error for an unknown template" do
    assert {:error, message} = Templates.generate("missing", "demo")
    assert message =~ "unknown template 'missing'"
    assert message =~ "web:"
  end
end
