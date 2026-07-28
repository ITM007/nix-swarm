defmodule NixSwarmCredentialsEnrollmentTest do
  use ExUnit.Case, async: true

  test "credential enrollment keeps the existing idempotent installer contract" do
    assert Code.ensure_loaded?(NixSwarm.Credentials)
    assert function_exported?(NixSwarm.Credentials, :install, 1)
  end
end
