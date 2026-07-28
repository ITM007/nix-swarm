defmodule NixSwarmApiTest do
  use ExUnit.Case, async: false

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

  describe "read-only operator surface" do
    test "returns local and cluster projections without mutating desired state" do
      local = API.local_status()
      cluster = API.cluster_status()
      members = API.cluster_members()
      overview = API.cluster_overview()

      assert local.node == Node.self()
      assert local.availability in [:active, :draining]
      assert is_binary(local.config_digest)
      assert is_map(local.operational_state)
      assert cluster.queried_node == Node.self()
      assert is_map(cluster.placements)
      assert is_list(cluster.placement_diagnostics)
      assert members.queried_node == Node.self()
      assert overview.members == members
      assert overview.status.queried_node == cluster.queried_node
      assert is_map(overview.ingress)
    end

    test "reads local systemd-backed logs and status projections" do
      assert is_list(API.local_node_service_logs(10))
      assert is_binary(API.local_cluster_logs(10))
      assert API.local_logs("not-configured", 10) == []
      assert API.logs("not-configured", 10) == []
      assert is_map(API.ingress_info())
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
      assert is_number(metrics.cpu.total)
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
