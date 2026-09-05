defmodule NixSwarmWeb.QueryBrokerTest do
  use ExUnit.Case, async: false

  alias NixSwarmWeb.QueryBroker

  defp start_broker(query_fun, opts \\ []) do
    name =
      Keyword.get(
        opts,
        :name,
        Module.concat(__MODULE__, "Broker#{System.unique_integer([:positive])}")
      )

    pubsub = Keyword.get(opts, :pubsub_server, Module.concat(__MODULE__, "PubSub"))
    start_supervised!({Phoenix.PubSub, name: pubsub})

    start_supervised!(
      {QueryBroker,
       [
         name: name,
         pubsub_server: pubsub,
         query_fun: query_fun,
         poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 60_000),
         start_immediately: false
       ]}
    )

    {name, pubsub}
  end

  test "ten subscribers over three refreshes produce three queries and broadcast snapshots" do
    parent = self()
    counter = Agent.start_link(fn -> 0 end) |> elem(1)

    {name, _pubsub} =
      start_broker(fn :cluster_overview ->
        Agent.update(counter, &(&1 + 1))
        %{"queried_node" => "test-node"}
      end)

    Enum.each(1..10, fn _ ->
      assert :ok = QueryBroker.subscribe(name)
    end)

    Enum.each(1..3, fn _ ->
      assert {:ok, snapshot} = QueryBroker.refresh(name)
      assert snapshot.stale? == false
      assert_receive {:cluster_snapshot, ^snapshot}, 500
    end)

    assert Agent.get(counter, & &1) == 3
    assert QueryBroker.snapshot(name).queried_node == "test-node"
    send(parent, :broker_test_complete)
    assert_receive :broker_test_complete
  end

  test "delivers cached snapshots immediately and keeps last good data stale on error" do
    test_pid = self()

    responses =
      Agent.start_link(fn -> [{:ok, %{"queried_node" => "node-a"}}, {:error, :timeout}] end)
      |> elem(1)

    {name, _pubsub} =
      start_broker(fn :cluster_overview ->
        Agent.get_and_update(responses, fn [head | tail] -> {head, tail} end)
      end)

    assert {:ok, snapshot} = QueryBroker.refresh(name)
    assert snapshot.queried_node == "node-a"
    assert :ok = QueryBroker.subscribe(name)
    assert_receive {:cluster_snapshot, ^snapshot}, 500

    assert {:error, :timeout} = QueryBroker.refresh(name)
    stale = QueryBroker.snapshot(name)
    assert stale.queried_node == "node-a"
    assert stale.stale?
    assert stale.errors != []
    assert QueryBroker.status(name).last_error == :timeout
    assert_receive {:cluster_snapshot, ^stale}, 500
    assert test_pid == self()
  end

  test "bounds polling and never schedules overlapping refreshes" do
    parent = self()
    blocker = make_ref()

    {name, _pubsub} =
      start_broker(
        fn :cluster_overview ->
          send(parent, {:query_started, self()})

          receive do
            ^blocker -> {:ok, %{"queried_node" => "node-a"}}
          end
        end,
        poll_interval_ms: 1
      )

    assert QueryBroker.poll_interval(name) == 1_000
    task = Task.async(fn -> QueryBroker.refresh(name) end)
    assert_receive {:query_started, query_pid}, 500
    refute_receive {:query_started, _}, 1_100
    send(query_pid, blocker)
    assert {:ok, _} = Task.await(task, 500)
    assert QueryBroker.status(name).in_flight? == false
  end

  test "coalesces identical on-demand log requests" do
    parent = self()

    {name, _pubsub} =
      start_broker(fn request ->
        send(parent, {:query, request})
        {:ok, %{"logs" => [request]}}
      end)

    task1 = Task.async(fn -> QueryBroker.logs(name, :service, "api", 200) end)
    task2 = Task.async(fn -> QueryBroker.logs(name, :service, "api", 200) end)
    assert {:ok, _} = Task.await(task1, 500)
    assert {:ok, _} = Task.await(task2, 500)
    assert_receive {:query, {:logs, "api", 200}}, 500
    refute_receive {:query, {:logs, "api", 200}}, 100
  end
end
