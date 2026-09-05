defmodule NixSwarmReconcilerStatefulTest do
  use ExUnit.Case, async: false

  alias NixSwarm.Reconciler

  defp base_config(root, db_dir, service_extra) do
    service =
      %{
        name: "db",
        replicas: 1,
        unit_template: "db.service",
        state: %{
          dirs: [db_dir],
          backup: %{target: "ssh://borg@backup/./db"}
        }
      }
      |> Map.merge(service_extra)

    %{
      peers: [Node.self()],
      nodes: %{Node.self() => %{}},
      services: [
        %{name: "api", replicas: 1, unit_template: "api.service"},
        service
      ],
      runtime: %{
        connect_interval_ms: 10_000,
        reconcile_interval_ms: 10_000,
        executor: %{adapter: :fake, root: root},
        generation: "reconciler-stateful-test"
      }
    }
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "nix-swarm-reconciler-stateful-#{System.unique_integer([:positive])}"
      )

    root = Path.join(tmp, "executor")
    db_dir = Path.join(tmp, "db-state")
    File.rm_rf!(tmp)
    File.mkdir_p!(root)

    previous_config = Application.get_env(:nix_swarm, :cluster_config)
    Application.stop(:nix_swarm)
    Application.put_env(:nix_swarm, :cluster_config, base_config(root, db_dir, %{}))

    on_exit(fn ->
      Application.stop(:nix_swarm)

      if previous_config do
        Application.put_env(:nix_swarm, :cluster_config, previous_config)
      else
        Application.delete_env(:nix_swarm, :cluster_config)
      end

      {:ok, _apps} = Application.ensure_all_started(:nix_swarm)
      File.rm_rf!(tmp)
    end)

    {:ok, _apps} = Application.ensure_all_started(:nix_swarm)
    {:ok, root: root, db_dir: db_dir}
  end

  defp db_service(status) do
    Enum.find(status, &(&1.name == "db"))
  end

  # The distributed controller node starts in :recovering membership and is
  # only admitted to placement after the recovery-stabilization timer fires.
  # Reconcile until a predicate holds so tests do not race that transition.
  defp reconcile_until(predicate, timeout_ms \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(&Reconciler.reconcile_now/0)
    |> Enum.reduce_while(nil, fn result, _acc ->
      cond do
        predicate.(result) ->
          {:halt, result}

        System.monotonic_time(:millisecond) > deadline ->
          raise "reconcile predicate not satisfied within #{timeout_ms} ms"

        true ->
          Process.sleep(100)
          {:cont, nil}
      end
    end)
  end

  defp api_running?(_result) do
    NixSwarm.Executor.unit_status("api.service") == {:ok, :running}
  end

  test "a stateful unit missing its state directory is not started and reports awaiting_heal",
       %{db_dir: db_dir} do
    reconcile_until(&api_running?/1)

    result = Reconciler.reconcile_now()

    assert result.awaiting_heal == %{"db.service" => [db_dir]}
    assert NixSwarm.Executor.unit_status("db.service") == {:ok, :stopped}

    # the stateless sibling starts normally and is never deferred
    assert NixSwarm.Executor.unit_status("api.service") == {:ok, :running}
    refute Map.has_key?(result.awaiting_heal, "api.service")

    status = Reconciler.local_status()
    db = db_service(status)

    assert db.awaiting_heal == ["db.service"]
    assert [%{unit: "db.service", status: :awaiting_heal}] = db.units
  end

  test "creating the state directory lets the next reconcile start the unit and clear awaiting_heal",
       %{db_dir: db_dir} do
    reconcile_until(fn result -> Map.has_key?(result.awaiting_heal, "db.service") end)

    File.mkdir_p!(db_dir)
    result = Reconciler.reconcile_now()

    assert result.awaiting_heal == %{}
    assert NixSwarm.Executor.unit_status("db.service") == {:ok, :running}

    status = Reconciler.local_status()
    db = db_service(status)
    assert db.awaiting_heal == []
    assert [%{unit: "db.service", status: :running}] = db.units
  end

  test "stateful restore none starts on first boot without state (fresh initialisation)",
       %{root: root, db_dir: db_dir} do
    Application.stop(:nix_swarm)

    config = base_config(root, db_dir, %{state: %{dirs: [db_dir]}})
    Application.put_env(:nix_swarm, :cluster_config, config)
    {:ok, _apps} = Application.ensure_all_started(:nix_swarm)

    reconcile_until(fn _result ->
      NixSwarm.Executor.unit_status("db.service") == {:ok, :running}
    end)

    result = Reconciler.reconcile_now()
    assert result.awaiting_heal == %{}
    assert NixSwarm.Executor.unit_status("db.service") == {:ok, :running}
  end
end
