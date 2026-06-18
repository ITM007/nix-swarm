defmodule NixSwarmReconcilerTest do
  use ExUnit.Case, async: false

  alias NixSwarm.Reconciler

  @test_config %{
    peers: [:"test-node@127.0.0.1"],
    nodes: %{
      :"test-node@127.0.0.1" => %{labels: ["apps"]}
    },
    services: [
      %{
        name: "api",
        replicas: 1,
        unit_template: "api.service",
        constraints: ["apps"],
        healthcheck: "echo ok"
      },
      %{
        name: "worker",
        replicas: 2,
        unit_template: "worker@%{slot}.service",
        constraints: ["apps"]
      }
    ],
    runtime: %{
      connect_interval_ms: 10_000,
      reconcile_interval_ms: 10_000,
      executor: %{adapter: :fake, root: nil},
      generation: "reconciler-test"
    }
  }

  setup do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-reconciler-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    config = put_in(@test_config.runtime.executor.root, root)
    Application.put_env(:nix_swarm, :cluster_config, config)

    on_exit(fn ->
      Application.stop(:nix_swarm)
      File.rm_rf!(root)
    end)

    {:ok, _} = Application.ensure_all_started(:nix_swarm)
    {:ok, root: root}
  end

  describe "reconcile_now/0" do
    test "returns a map with expected keys" do
      result = Reconciler.reconcile_now()
      assert is_map(result)
      assert Map.has_key?(result, :owned_units)
      assert Map.has_key?(result, :results)
      assert is_list(result.results)
    end

    test "repeated reconciles are idempotent" do
      r1 = Reconciler.reconcile_now()
      r2 = Reconciler.reconcile_now()
      assert r1.owned_units == r2.owned_units
    end
  end

  describe "local_status/0" do
    test "returns a list of services with expected fields" do
      status = Reconciler.local_status()
      assert is_list(status)
      assert length(status) == 2

      api_service = Enum.find(status, &(&1.name == "api"))
      assert api_service != nil
      assert Map.has_key?(api_service, :name)
      assert Map.has_key?(api_service, :units)
      assert Map.has_key?(api_service, :desired_state)

      assert api_service.desired_state == :running
    end

    test "each unit has status, slot, and unit fields" do
      status = Reconciler.local_status()

      Enum.each(status, fn service ->
        Enum.each(service.units, fn unit ->
          assert Map.has_key?(unit, :slot)
          assert Map.has_key?(unit, :unit)
          assert Map.has_key?(unit, :status)
        end)
      end)
    end
  end

  describe "local_service_modes/0" do
    test "returns an empty map initially" do
      assert Reconciler.local_service_modes() == %{}
    end
  end

  describe "start_local_service/1" do
    test "returns ok for a known service" do
      result = Reconciler.start_local_service("api")
      assert is_map(result)
      assert result.desired_state == :running
    end

    test "returns error for an unknown service" do
      assert {:error, :unknown_service} = Reconciler.start_local_service("nonexistent")
    end
  end

  describe "stop_local_service/1" do
    test "stops a running service and updates desired state" do
      {:ok, _} = Application.ensure_all_started(:nix_swarm)

      result = Reconciler.stop_local_service("api")
      assert is_map(result)
      assert result.desired_state == :stopped

      status = Reconciler.local_status()
      api_service = Enum.find(status, &(&1.name == "api"))
      assert api_service.desired_state == :stopped
    end
  end

  describe "restart_local_service/1" do
    test "restarts a running service" do
      result = Reconciler.restart_local_service("api")
      assert is_list(result)

      Enum.each(result, fn {unit_name, restart_result} ->
        assert is_binary(unit_name)
        assert restart_result == :ok
      end)
    end

    test "returns error for an unknown service" do
      assert {:error, :unknown_service} = Reconciler.restart_local_service("nonexistent")
    end
  end

  describe "healthcheck" do
    test "reconcile_now reports healthcheck results for services that define one" do
      result = Reconciler.reconcile_now()
      assert Map.has_key?(result, :healthcheck)
      assert is_map(result.healthcheck)
      assert Map.has_key?(result.healthcheck, "api")
      assert result.healthcheck["api"].healthy == true
    end

    test "local_status includes healthcheck results" do
      Reconciler.reconcile_now()
      status = Reconciler.local_status()
      api_service = Enum.find(status, &(&1.name == "api"))
      assert api_service.healthcheck != nil
      assert api_service.healthcheck.healthy == true
    end
  end
end
