defmodule NixSwarmApplicationTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Application

  describe "pure_invocation?/1" do
    test "--version alone is a pure invocation" do
      assert Application.pure_invocation?(["--version"])
    end

    test "--help alone is a pure invocation" do
      assert Application.pure_invocation?(["--help"])
    end

    test "--version anywhere in the argv wins" do
      assert Application.pure_invocation?(["cluster", "status", "--json", "--version"])
      assert Application.pure_invocation?(["--version", "cluster", "apply"])
    end

    test "--help combined with a subcommand is still pure" do
      assert Application.pure_invocation?(["cluster", "apply", "--help"])
    end

    test "ordinary invocations are not pure" do
      refute Application.pure_invocation?([])
      refute Application.pure_invocation?(["cluster", "apply", "--yes"])
      refute Application.pure_invocation?(["help"])
    end
  end
end
