defmodule NixSwarmRPCTest do
  use ExUnit.Case, async: true

  alias NixSwarm.RPC

  test "normalizes local calls, exceptions, and bang calls" do
    assert {:ok, 3} = RPC.call(Node.self(), Enum, :count, [[1, 2, 3]])
    assert 6 = RPC.call!(Node.self(), Enum, :sum, [[1, 2, 3]])

    assert {:error, {:exception, %UndefinedFunctionError{}, stacktrace}} =
             RPC.call(Node.self(), String, :definitely_missing, [])

    assert is_list(stacktrace)

    assert_raise RuntimeError, ~r/RPC .* failed/, fn ->
      RPC.call!(Node.self(), String, :definitely_missing, [])
    end
  end

  test "local casts execute asynchronously" do
    assert :ok = RPC.cast(Node.self(), Process, :send, [self(), :rpc_cast_complete, []])
    assert_receive :rpc_cast_complete
  end

  test "multicall preserves node association and legacy errors" do
    assert [{node, {:ok, 2}}] = RPC.multicall([Node.self()], Enum, :count, [[:a, :b]])
    assert node == Node.self()

    assert {:badrpc, {:exception, %UndefinedFunctionError{}, _stacktrace}} =
             RPC.legacy_call(Node.self(), String, :definitely_missing, [], 100)
  end

  test "remote calls return bounded erpc errors" do
    missing_node = :"missing-rpc-node@127.0.0.1"
    assert {:error, {_class, _reason}} = RPC.call(missing_node, Enum, :count, [[]], 25)
  end
end
