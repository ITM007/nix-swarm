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

    previous_config = Application.get_env(:nix_swarm, :cluster_config)
    config = put_in(@test_config.runtime.executor.root, root)
    Application.stop(:nix_swarm)
    Application.put_env(:nix_swarm, :cluster_config, config)

    on_exit(fn ->
      Application.stop(:nix_swarm)

      if previous_config do
        Application.put_env(:nix_swarm, :cluster_config, previous_config)
      else
        Application.delete_env(:nix_swarm, :cluster_config)
      end

      {:ok, _apps} = Application.ensure_all_started(:nix_swarm)
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

    test "emits telemetry spans" do
      handler_id = "reconcile-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [[:nix_swarm, :reconcile, :start], [:nix_swarm, :reconcile, :stop]],
          fn event, measurements, metadata, pid ->
            send(pid, {:telemetry, event, measurements, metadata})
          end,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      Reconciler.reconcile_now()

      assert_receive {:telemetry, [:nix_swarm, :reconcile, :start], _, %{node: _}}
      assert_receive {:telemetry, [:nix_swarm, :reconcile, :stop], %{duration: duration}, _}
      assert duration > 0
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

  describe "code-first durable state" do
    test "records the applied Nix generation and assignments across restarts" do
      result = Reconciler.reconcile_now()
      snapshot = NixSwarm.OperationalState.snapshot()

      assert snapshot.generation == "reconciler-test"
      assert snapshot.config_digest == NixSwarm.Config.digest()
      assert snapshot.owned_units == result.owned_units
      assert is_list(snapshot.assignments)

      assert :ok = Application.stop(:nix_swarm)
      assert {:ok, _apps} = Application.ensure_all_started(:nix_swarm)
      assert NixSwarm.OperationalState.snapshot() == snapshot
    end

    test "does not expose mutable service control functions" do
      refute function_exported?(Reconciler, :start_local_service, 1)
      refute function_exported?(Reconciler, :stop_local_service, 1)
      refute function_exported?(Reconciler, :restart_local_service, 1)
    end
  end

  describe "systemd health" do
    test "reconcile_now derives health from unit state without executing shell commands" do
      result = Reconciler.reconcile_now()
      assert Map.has_key?(result, :healthcheck)
      assert is_map(result.healthcheck)
      assert Map.has_key?(result.healthcheck, "api")
      assert result.healthcheck["api"].source == :systemd
      assert is_boolean(result.healthcheck["api"].healthy)
      refute Map.has_key?(result.healthcheck["api"], :output)
    end

    test "local_status includes systemd-derived health results" do
      Reconciler.reconcile_now()
      status = Reconciler.local_status()
      api_service = Enum.find(status, &(&1.name == "api"))
      assert api_service.healthcheck != nil
      assert api_service.healthcheck.source == :systemd
      assert is_map(api_service.healthcheck.units)
    end
  end
end
