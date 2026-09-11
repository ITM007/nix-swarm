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
         start_immediately: Keyword.get(opts, :start_immediately, false),
         query_timeout_ms: Keyword.get(opts, :query_timeout_ms, 15_000),
         max_log_tasks: Keyword.get(opts, :max_log_tasks, 8),
         log_cache_ttl_ms: Keyword.get(opts, :log_cache_ttl_ms, 60_000),
         max_log_cache_entries: Keyword.get(opts, :max_log_cache_entries, 32),
         max_log_cache_bytes: Keyword.get(opts, :max_log_cache_bytes, 1_024 * 1_024)
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

  test "serves cached snapshots and status while a refresh query is running" do
    parent = self()
    blocker = make_ref()

    {name, _pubsub} =
      start_broker(fn :cluster_overview ->
        send(parent, {:query_started, self()})

        receive do
          ^blocker -> {:ok, %{"queried_node" => "fresh"}}
        end
      end)

    assert :ok = QueryBroker.put_snapshot(name, %{"queried_node" => "cached"})

    refresh_task = Task.async(fn -> QueryBroker.refresh(name) end)
    assert_receive {:query_started, query_pid}, 500

    snapshot_task = Task.async(fn -> QueryBroker.snapshot(name) end)
    assert {:ok, snapshot} = Task.yield(snapshot_task, 500)
    assert snapshot.queried_node == "cached"

    status_task = Task.async(fn -> QueryBroker.status(name) end)
    assert {:ok, status} = Task.yield(status_task, 500)
    assert status.in_flight?

    send(query_pid, blocker)
    assert {:ok, fresh} = Task.await(refresh_task, 500)
    assert fresh.queried_node == "fresh"
  end

  test "times out a slow refresh while keeping cached data available" do
    parent = self()
    blocker = make_ref()

    {name, _pubsub} =
      start_broker(
        fn :cluster_overview ->
          send(parent, {:query_started, self()})

          receive do
            ^blocker -> {:ok, %{"queried_node" => "never-reached"}}
          end
        end,
        query_timeout_ms: 50
      )

    assert :ok = QueryBroker.put_snapshot(name, %{"queried_node" => "cached"})

    refresh_task = Task.async(fn -> QueryBroker.refresh(name) end)
    assert_receive {:query_started, _query_pid}, 500

    assert {:ok, snapshot} = Task.yield(Task.async(fn -> QueryBroker.snapshot(name) end), 500)
    assert snapshot.queried_node == "cached"
    assert {:error, :timeout} = Task.await(refresh_task, 500)
    assert QueryBroker.status(name).in_flight? == false
    assert QueryBroker.snapshot(name).stale?
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

  test "auto-polling refreshes on the scheduled interval without manual refresh" do
    counter = Agent.start_link(fn -> 0 end) |> elem(1)

    {name, _pubsub} =
      start_broker(
        fn :cluster_overview ->
          Agent.update(counter, &(&1 + 1))
          {:ok, %{"queried_node" => "node-a"}}
        end,
        poll_interval_ms: 1,
        start_immediately: true
      )

    assert QueryBroker.poll_interval(name) == 1_000
    # The first scheduled poll fires immediately; at least two more follow at 1s.
    assert eventually(fn -> Agent.get(counter, & &1) >= 3 end, 3_000)
    assert QueryBroker.status(name).last_error == nil
    assert QueryBroker.snapshot(name).queried_node == "node-a"
  end

  defp eventually(predicate, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    predicate.() ||
      if System.monotonic_time(:millisecond) > deadline do
        false
      else
        Process.sleep(50)
        eventually(predicate, timeout_ms)
      end
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

  test "cancels obsolete log work when the only caller disappears" do
    parent = self()
    blocker = make_ref()

    {name, _pubsub} =
      start_broker(fn
        {:logs, "api", 200} ->
          send(parent, {:query_started, self()})

          receive do
            ^blocker ->
              send(parent, :query_completed)
              {:ok, %{"logs" => ["stale"]}}
          end
      end)

    caller = Task.async(fn -> QueryBroker.logs(name, :service, "api", 200) end)
    assert_receive {:query_started, query_pid}, 500
    Task.shutdown(caller, :brutal_kill)

    assert eventually(fn -> not Process.alive?(query_pid) end, 500)
    refute_receive :query_completed, 100
  end

  test "rejects distinct log work after the bounded admission limit" do
    parent = self()
    blocker = make_ref()

    {name, _pubsub} =
      start_broker(
        fn {:logs, service, 200} ->
          send(parent, {:query_started, service, self()})

          receive do
            ^blocker -> {:ok, %{"logs" => [service]}}
          end
        end,
        max_log_tasks: 2
      )

    first = Task.async(fn -> QueryBroker.logs(name, :service, "one", 200) end)
    second = Task.async(fn -> QueryBroker.logs(name, :service, "two", 200) end)
    assert_receive {:query_started, "one", _}, 500
    assert_receive {:query_started, "two", _}, 500

    third = Task.async(fn -> QueryBroker.logs(name, :service, "three", 200) end)
    assert {:ok, {:error, :busy}} = Task.yield(third, 500)

    Task.shutdown(first, :brutal_kill)
    Task.shutdown(second, :brutal_kill)
  end

  test "expires log cache entries without waiting for an overview refresh" do
    counter = Agent.start_link(fn -> 0 end) |> elem(1)

    {name, _pubsub} =
      start_broker(
        fn {:logs, service, 200} ->
          Agent.update(counter, &(&1 + 1))
          {:ok, %{"logs" => [service]}}
        end,
        log_cache_ttl_ms: 20
      )

    assert {:ok, _} = QueryBroker.logs(name, :service, "api", 200)
    assert {:ok, _} = QueryBroker.logs(name, :service, "api", 200)
    assert Agent.get(counter, & &1) == 1

    Process.sleep(30)
    assert {:ok, _} = QueryBroker.logs(name, :service, "api", 200)
    assert Agent.get(counter, & &1) == 2
  end

  test "evicts the oldest successful log result at the entry limit" do
    counter = Agent.start_link(fn -> 0 end) |> elem(1)

    {name, _pubsub} =
      start_broker(
        fn {:logs, service, 200} ->
          Agent.update(counter, &(&1 + 1))
          {:ok, %{"logs" => [service]}}
        end,
        max_log_cache_entries: 1
      )

    assert {:ok, _} = QueryBroker.logs(name, :service, "one", 200)
    assert {:ok, _} = QueryBroker.logs(name, :service, "two", 200)
    assert {:ok, _} = QueryBroker.logs(name, :service, "one", 200)
    assert Agent.get(counter, & &1) == 3
  end

  test "does not cache a successful result above the byte limit" do
    counter = Agent.start_link(fn -> 0 end) |> elem(1)

    {name, _pubsub} =
      start_broker(
        fn {:logs, "api", 200} ->
          Agent.update(counter, &(&1 + 1))
          {:ok, %{"logs" => ["result"]}}
        end,
        max_log_cache_bytes: 1
      )

    assert {:ok, _} = QueryBroker.logs(name, :service, "api", 200)
    assert {:ok, _} = QueryBroker.logs(name, :service, "api", 200)
    assert Agent.get(counter, & &1) == 2
  end
end
