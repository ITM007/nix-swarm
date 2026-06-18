defmodule NixSwarmApiTest do
  use ExUnit.Case, async: true

  alias NixSwarm.API

  describe "version/0" do
    test "returns a non-empty version string" do
      version = API.version()
      assert is_binary(version)
      assert byte_size(version) > 0
    end

    test "returns the same value on repeated calls (cached)" do
      v1 = API.version()
      v2 = API.version()
      assert v1 == v2
    end
  end

  describe "network_info/0" do
    test "returns a map with ips and ports keys" do
      info = API.network_info()
      assert is_map(info)
      assert Map.has_key?(info, :ips)
      assert is_list(info.ips)
      assert Map.has_key?(info, :ports)
      assert is_list(info.ports)
    end

    test "does not include loopback in ips" do
      info = API.network_info()
      refute "127.0.0.1" in info.ips
    end

    test "includes common ports" do
      info = API.network_info()
      assert 4369 in info.ports
      assert 4370 in info.ports
    end
  end

  describe "node_metrics/0" do
    test "returns a map with expected metric groups" do
      metrics = API.node_metrics()

      assert is_map(metrics)
      assert Map.has_key?(metrics, :cpu)
      assert Map.has_key?(metrics, :memory)
      assert Map.has_key?(metrics, :disk)
      assert Map.has_key?(metrics, :network)
      assert Map.has_key?(metrics, :uptime)

      assert is_map(metrics.cpu)
      assert is_map(metrics.memory)
      assert is_map(metrics.disk)
      assert is_map(metrics.network)
      assert is_integer(metrics.uptime)
    end

    test "cpu has valid fields" do
      metrics = API.node_metrics()
      assert is_number(metrics.cpu.used)
      assert is_integer(metrics.cpu.total) or is_number(metrics.cpu.total)
      assert is_integer(metrics.cpu.pct)
      assert metrics.cpu.pct >= 0 and metrics.cpu.pct <= 100
    end

    test "memory has valid fields" do
      metrics = API.node_metrics()
      assert is_integer(metrics.memory.used)
      assert is_integer(metrics.memory.total)
      assert is_integer(metrics.memory.pct)
    end

    test "disk has valid fields" do
      metrics = API.node_metrics()
      assert is_integer(metrics.disk.used)
      assert is_integer(metrics.disk.total)
      assert is_integer(metrics.disk.pct)
    end

    test "network has valid fields" do
      metrics = API.node_metrics()
      assert is_integer(metrics.network.received)
      assert is_integer(metrics.network.transmitted)
      assert is_integer(metrics.network.total)
    end
  end
end
