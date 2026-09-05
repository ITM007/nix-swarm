defmodule NixSwarmWeb.SnapshotFixture do
  @fixture Path.expand("../fixtures/operator_snapshot.json", __DIR__)

  def snapshot do
    @fixture
    |> File.read!()
    |> :json.decode()
    |> NixSwarmWeb.ClusterSnapshot.normalize(captured_at: ~U[2026-09-05 12:00:00Z])
  end

  def broker_setup(test_module) do
    pubsub = Module.concat(test_module, PubSub)
    broker = Module.concat(test_module, Broker)

    {:ok, pubsub_supervisor} =
      Supervisor.start_link([{Phoenix.PubSub, name: pubsub}], strategy: :one_for_one)

    Process.unlink(pubsub_supervisor)

    {:ok, broker_pid} =
      NixSwarmWeb.QueryBroker.start_link(
        name: broker,
        pubsub_server: pubsub,
        start_immediately: false,
        query_fun: fn _request -> {:ok, %{}} end
      )

    Process.unlink(broker_pid)

    NixSwarmWeb.QueryBroker.put_snapshot(broker, snapshot())
    Application.put_env(:nix_swarm_web, :query_broker_name, broker)
    Application.put_env(:nix_swarm_web, :pubsub_server, pubsub)

    %{broker: broker, pubsub: pubsub, pubsub_supervisor: pubsub_supervisor, snapshot: snapshot()}
  end

  def stop(%{broker: broker, pubsub_supervisor: pubsub_supervisor}) do
    Application.delete_env(:nix_swarm_web, :query_broker_name)
    Application.delete_env(:nix_swarm_web, :pubsub_server)

    safe_stop(fn ->
      if pid = Process.whereis(broker), do: GenServer.stop(pid, :normal, 1_000)
    end)

    safe_stop(fn ->
      if Process.alive?(pubsub_supervisor), do: Supervisor.stop(pubsub_supervisor, :normal, 1_000)
    end)

    :ok
  end

  defp safe_stop(fun) do
    fun.()
  catch
    :exit, _reason -> :ok
  end
end
