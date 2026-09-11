defmodule NixSwarmWeb.QueryBroker do
  @moduledoc """
  One supervised, cached query loop for all web consumers.

  LiveViews subscribe to the `cluster:snapshot` PubSub topic and never open the
  query socket themselves. A poll is executed by one monitored worker, so a
  slow query cannot block cached reads or create a second poll or a
  per-browser request storm.
  """

  use GenServer

  alias NixSwarmWeb.{ClusterSnapshot, MetricHistory}

  @snapshot_topic "cluster:snapshot"
  @default_interval_ms 5_000
  @min_interval_ms 1_000
  @max_interval_ms 60_000
  @default_timeout_ms 15_000
  @max_log_lines 1_000
  @default_max_log_tasks 8
  @default_log_cache_ttl_ms 60_000
  @default_max_log_cache_entries 32
  @default_max_log_cache_bytes 1 * 1_024 * 1_024

  @type state :: %{
          query_fun: function(),
          query_timeout_ms: pos_integer(),
          interval_ms: pos_integer(),
          pubsub_server: atom(),
          current_snapshot: map() | nil,
          last_good_snapshot: map() | nil,
          last_good_at: DateTime.t() | nil,
          last_error: term() | nil,
          consecutive_failures: non_neg_integer(),
          in_flight?: boolean(),
          timer_ref: reference() | nil,
          poll_ref: reference() | nil,
          query_task: Task.t() | nil,
          query_timeout_ref: reference() | nil,
          refresh_waiters: list(),
          metric_history: MetricHistory.t(),
          log_cache: map(),
          log_cache_bytes: non_neg_integer(),
          log_cache_ttl_ms: pos_integer(),
          max_log_cache_entries: pos_integer(),
          max_log_cache_bytes: pos_integer(),
          max_log_tasks: pos_integer(),
          log_task_supervisor: atom() | pid(),
          log_tasks: map()
        }

  @doc "Starts one broker; pass `name` for an isolated test broker."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the configured application broker name."
  def broker_name do
    Application.get_env(:nix_swarm_web, :query_broker_name, __MODULE__)
  end

  @doc "Subscribes the calling process and immediately sends the cached snapshot."
  def subscribe(name \\ broker_name(), topic \\ @snapshot_topic) do
    pubsub = pubsub_server(name)
    :ok = Phoenix.PubSub.subscribe(pubsub, topic)

    case snapshot(name) do
      snapshot when is_map(snapshot) -> send(self(), {:cluster_snapshot, snapshot})
      _ -> :ok
    end

    :ok
  end

  @doc "Returns the current projection, including stale metadata after errors."
  def snapshot(name \\ broker_name()), do: call_if_started(name, :snapshot, nil)
  def current_snapshot(name \\ broker_name()), do: snapshot(name)

  @doc "Returns broker health and freshness metadata."
  def status(name \\ broker_name()), do: call_if_started(name, :status, default_status())

  @doc "Runs one bounded refresh immediately and returns its result."
  def refresh(name \\ broker_name()),
    do:
      call_if_started(name, :refresh, {:error, :broker_unavailable}, @default_timeout_ms + 1_000)

  def refresh_now(name \\ broker_name()), do: refresh(name)

  @doc "Returns the normalized polling interval."
  def poll_interval(name \\ broker_name()),
    do: call_if_started(name, :poll_interval, @default_interval_ms)

  @doc "Returns the PubSub server used by a broker."
  def pubsub_server(name \\ broker_name()) do
    call_if_started(
      name,
      :pubsub_server,
      Application.get_env(:nix_swarm_web, :pubsub_server, NixSwarmWeb.PubSub)
    )
  end

  @doc false
  def put_snapshot(name \\ broker_name(), snapshot) when is_map(snapshot) do
    GenServer.call(name, {:put_snapshot, snapshot})
  end

  @doc "Fetches a bounded log through the shared broker."
  def logs(name \\ broker_name(), scope, target, lines \\ 200) do
    GenServer.call(name, {:logs, scope, target, lines}, @default_timeout_ms + 1_000)
  catch
    :exit, _reason -> {:error, :broker_unavailable}
  end

  def query_log(name \\ broker_name(), scope, target, lines \\ 200),
    do: logs(name, scope, target, lines)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    query_fun = Keyword.get(opts, :query_fun, &default_query/1)

    interval_ms =
      bounded_interval(
        Keyword.get(
          opts,
          :poll_interval_ms,
          Keyword.get(opts, :poll_interval, @default_interval_ms)
        )
      )

    pubsub_server =
      Keyword.get(
        opts,
        :pubsub_server,
        Application.get_env(:nix_swarm_web, :pubsub_server, NixSwarmWeb.PubSub)
      )

    start_immediately = Keyword.get(opts, :start_immediately, true)

    query_timeout_ms =
      bounded_timeout(Keyword.get(opts, :query_timeout_ms, @default_timeout_ms))

    state = %{
      query_fun: query_fun,
      query_timeout_ms: query_timeout_ms,
      interval_ms: interval_ms,
      pubsub_server: pubsub_server,
      log_cache_ttl_ms:
        bounded_cache_value(
          Keyword.get(opts, :log_cache_ttl_ms, @default_log_cache_ttl_ms),
          @default_log_cache_ttl_ms,
          86_400_000
        ),
      max_log_cache_entries:
        bounded_cache_value(
          Keyword.get(opts, :max_log_cache_entries, @default_max_log_cache_entries),
          @default_max_log_cache_entries,
          1_000
        ),
      max_log_cache_bytes:
        bounded_cache_value(
          Keyword.get(opts, :max_log_cache_bytes, @default_max_log_cache_bytes),
          @default_max_log_cache_bytes,
          16 * 1_024 * 1_024
        ),
      max_log_tasks:
        bounded_cache_value(
          Keyword.get(opts, :max_log_tasks, @default_max_log_tasks),
          @default_max_log_tasks,
          @default_max_log_tasks
        ),
      log_task_supervisor:
        Keyword.get(opts, :log_task_supervisor, NixSwarmWeb.QueryTaskSupervisor),
      current_snapshot: nil,
      last_good_snapshot: nil,
      last_good_at: nil,
      last_error: nil,
      consecutive_failures: 0,
      in_flight?: false,
      timer_ref: nil,
      poll_ref: nil,
      query_task: nil,
      query_timeout_ref: nil,
      refresh_waiters: [],
      metric_history: MetricHistory.new(120),
      log_cache: %{},
      log_cache_bytes: 0,
      log_tasks: %{}
    }

    {:ok, schedule_next(state, if(start_immediately, do: 0, else: interval_ms))}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.current_snapshot, state}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       stale?: stale?(state.current_snapshot),
       in_flight?: state.in_flight?,
       last_good_at: state.last_good_at,
       last_error: state.last_error,
       consecutive_failures: state.consecutive_failures,
       interval_ms: state.interval_ms,
       metric_samples: length(MetricHistory.samples(state.metric_history))
     }, state}
  end

  def handle_call(:poll_interval, _from, state), do: {:reply, state.interval_ms, state}
  def handle_call(:pubsub_server, _from, state), do: {:reply, state.pubsub_server, state}

  def handle_call(:refresh, from, %{in_flight?: true} = state),
    do: {:noreply, %{state | refresh_waiters: [from | state.refresh_waiters]}}

  def handle_call(:refresh, from, state),
    do: {:noreply, start_refresh(state, [from])}

  def handle_call({:put_snapshot, snapshot}, _from, state) do
    normalized =
      if Map.has_key?(snapshot, :captured_at) and Map.has_key?(snapshot, :stale?),
        do: snapshot,
        else: ClusterSnapshot.normalize(snapshot)

    {:reply, :ok,
     %{
       state
       | current_snapshot: normalized,
         last_good_snapshot: normalized,
         last_good_at: normalized.captured_at,
         last_error: nil,
         consecutive_failures: 0
     }}
  end

  def handle_call({:logs, scope, target, lines}, from, state) do
    state = purge_expired_log_cache(state)

    with {:ok, request, key} <- log_request(scope, target, lines) do
      case Map.fetch(state.log_cache, key) do
        {:ok, %{response: response}} ->
          {:reply, response, state}

        :error ->
          case Map.get(state.log_tasks, key) do
            nil when map_size(state.log_tasks) >= state.max_log_tasks ->
              {:reply, {:error, :busy}, state}

            nil ->
              start_log_task(state, request, key, from)

            task_info ->
              {:noreply, put_log_waiter(state, key, task_info, from)}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:poll, poll_ref}, %{poll_ref: poll_ref} = state) do
    {:noreply, start_refresh(%{state | poll_ref: nil, timer_ref: nil})}
  end

  def handle_info({:poll, _stale_poll_ref}, state), do: {:noreply, state}

  def handle_info(:poll, state) do
    {:noreply, start_refresh(%{state | timer_ref: nil})}
  end

  def handle_info({query_ref, result}, %{query_task: %{ref: query_ref}} = state) do
    {:noreply, finish_refresh(state, normalize_query_result(result))}
  end

  def handle_info(
        {:DOWN, query_ref, :process, _pid, reason},
        %{query_task: %{ref: query_ref}} = state
      ) do
    {:noreply, finish_refresh(state, {:error, reason})}
  end

  def handle_info({query_ref, result}, state) when is_reference(query_ref) do
    case log_key_for_ref(state.log_tasks, query_ref) do
      nil -> {:noreply, state}
      key -> {:noreply, finish_log(state, key, normalize_query_result(result))}
    end
  end

  def handle_info({:DOWN, query_ref, :process, _pid, reason}, state) do
    case log_key_for_ref(state.log_tasks, query_ref) do
      nil -> {:noreply, remove_log_waiter(state, query_ref)}
      key -> {:noreply, finish_log(state, key, {:error, reason})}
    end
  end

  def handle_info({:log_timeout, key, task_ref}, state) do
    case Map.get(state.log_tasks, key) do
      %{task: %{ref: ^task_ref, pid: pid}} ->
        Process.exit(pid, :kill)
        {:noreply, finish_log(state, key, {:error, :timeout})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:query_timeout, query_ref}, %{query_task: %{ref: query_ref, pid: pid}} = state) do
    Process.exit(pid, :kill)
    {:noreply, finish_refresh(state, {:error, :timeout})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)
    stop_query_task(state.query_task, state.query_timeout_ref)
    Enum.each(state.log_tasks, fn {_key, %{task: task}} -> Process.exit(task.pid, :kill) end)
    :ok
  end

  defp start_refresh(%{in_flight?: true} = state, _waiters), do: state

  defp start_refresh(state, waiters) do
    cancel_timer(state.timer_ref)
    task = Task.async(fn -> invoke_query(state.query_fun, :cluster_overview, state) end)
    timeout_ref = Process.send_after(self(), {:query_timeout, task.ref}, state.query_timeout_ms)

    %{
      state
      | in_flight?: true,
        timer_ref: nil,
        poll_ref: nil,
        query_task: task,
        query_timeout_ref: timeout_ref,
        refresh_waiters: waiters
    }
  end

  defp start_refresh(state), do: start_refresh(state, [])

  defp finish_refresh(state, result) do
    task_ref = state.query_task.ref
    waiters = state.refresh_waiters
    Process.demonitor(task_ref, [:flush])
    cancel_timer(state.query_timeout_ref)

    state = %{
      state
      | in_flight?: false,
        query_task: nil,
        query_timeout_ref: nil,
        refresh_waiters: []
    }

    {reply, state} = apply_refresh_result(state, result)
    Enum.each(waiters, &GenServer.reply(&1, reply))
    schedule_next(state, state.interval_ms)
  end

  defp apply_refresh_result(state, {:ok, payload}) do
    captured_at = DateTime.utc_now()
    snapshot = ClusterSnapshot.normalize(payload, captured_at: captured_at)
    previous = List.last(MetricHistory.samples(state.metric_history))

    delta =
      if previous,
        do: MetricHistory.delta(previous, snapshot),
        else: %{
          valid?: false,
          elapsed_ms: 0,
          cpu: nil,
          network: nil,
          service_cpu: %{},
          node_network: %{},
          service_network: %{},
          proxy_network: %{}
        }

    snapshot = put_in(snapshot, [:metrics, :rates], delta)
    history = MetricHistory.push(state.metric_history, snapshot)

    state = %{
      state
      | current_snapshot: snapshot,
        last_good_snapshot: snapshot,
        last_good_at: captured_at,
        last_error: nil,
        consecutive_failures: 0,
        metric_history: history,
        log_cache: %{},
        log_cache_bytes: 0
    }

    broadcast(state, snapshot)
    {{:ok, snapshot}, state}
  end

  defp apply_refresh_result(state, {:error, reason}) do
    snapshot = stale_snapshot(state, reason)

    state = %{
      state
      | current_snapshot: snapshot,
        last_error: reason,
        consecutive_failures: state.consecutive_failures + 1
    }

    broadcast(state, snapshot)
    {{:error, reason}, state}
  end

  defp normalize_query_result({:ok, payload}), do: {:ok, payload}
  defp normalize_query_result(payload) when is_map(payload), do: {:ok, payload}
  defp normalize_query_result({:error, reason}), do: {:error, reason}
  defp normalize_query_result(result), do: {:error, result}

  defp stop_query_task(nil, timeout_ref), do: cancel_timer(timeout_ref)

  defp stop_query_task(task, timeout_ref) do
    cancel_timer(timeout_ref)
    Process.exit(task.pid, :kill)
    Process.demonitor(task.ref, [:flush])
  end

  defp start_log_task(state, request, key, from) do
    case start_log_worker(state, request) do
      {:ok, task} ->
        timeout_ref =
          Process.send_after(self(), {:log_timeout, key, task.ref}, state.query_timeout_ms)

        task_info = %{
          task: task,
          timeout_ref: timeout_ref,
          waiters: [new_log_waiter(from)]
        }

        {:noreply, %{state | log_tasks: Map.put(state.log_tasks, key, task_info)}}

      {:error, _reason} ->
        {:reply, {:error, :busy}, state}
    end
  end

  defp start_log_worker(state, request) do
    worker = fn -> invoke_query(state.query_fun, request, state) end

    if is_pid(Process.whereis(state.log_task_supervisor)) do
      {:ok, Task.Supervisor.async_nolink(state.log_task_supervisor, worker)}
    else
      {:ok, Task.async(worker)}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp new_log_waiter({pid, _tag} = from), do: {from, Process.monitor(pid)}

  defp put_log_waiter(state, key, task_info, from) do
    task_info = %{task_info | waiters: [new_log_waiter(from) | task_info.waiters]}
    %{state | log_tasks: Map.put(state.log_tasks, key, task_info)}
  end

  defp finish_log(state, key, response) do
    %{task: task, timeout_ref: timeout_ref, waiters: waiters} = Map.fetch!(state.log_tasks, key)
    Process.demonitor(task.ref, [:flush])
    cancel_timer(timeout_ref)

    state = %{state | log_tasks: Map.delete(state.log_tasks, key)}
    state = if match?({:ok, _}, response), do: cache_log(state, key, response), else: state
    reply_log_waiters(waiters, response)
    state
  end

  defp reply_log_waiters(waiters, response) do
    Enum.each(waiters, fn {from, monitor_ref} ->
      Process.demonitor(monitor_ref, [:flush])
      GenServer.reply(from, response)
    end)
  end

  defp log_key_for_ref(log_tasks, ref) do
    Enum.find_value(log_tasks, fn
      {key, %{task: %{ref: ^ref}}} -> key
      _entry -> nil
    end)
  end

  defp remove_log_waiter(state, monitor_ref) do
    case Enum.find(state.log_tasks, fn {_key, %{waiters: waiters}} ->
           Enum.any?(waiters, fn {_from, ref} -> ref == monitor_ref end)
         end) do
      nil ->
        state

      {key, %{task: task, timeout_ref: timeout_ref, waiters: waiters} = task_info} ->
        remaining = Enum.reject(waiters, fn {_from, ref} -> ref == monitor_ref end)

        if remaining == [] do
          Process.exit(task.pid, :kill)
          Process.demonitor(task.ref, [:flush])
          cancel_timer(timeout_ref)
          %{state | log_tasks: Map.delete(state.log_tasks, key)}
        else
          %{state | log_tasks: Map.put(state.log_tasks, key, %{task_info | waiters: remaining})}
        end
    end
  end

  defp cache_log(state, key, response) do
    size = :erlang.external_size(response)

    if size > state.max_log_cache_bytes do
      state
    else
      previous_size = get_in(state.log_cache, [key, :size]) || 0

      cache =
        Map.put(state.log_cache, key, %{
          response: response,
          size: size,
          stored_at: System.monotonic_time(:millisecond)
        })

      trim_log_cache(%{
        state
        | log_cache: cache,
          log_cache_bytes: state.log_cache_bytes - previous_size + size
      })
    end
  end

  defp trim_log_cache(state) do
    {cache, bytes} =
      state.log_cache
      |> Enum.sort_by(fn {_key, entry} -> entry.stored_at end)
      |> Enum.reduce_while({state.log_cache, state.log_cache_bytes}, fn {key, entry},
                                                                        {cache, bytes} ->
        if map_size(cache) <= state.max_log_cache_entries and bytes <= state.max_log_cache_bytes do
          {:halt, {cache, bytes}}
        else
          {:cont, {Map.delete(cache, key), bytes - entry.size}}
        end
      end)

    %{state | log_cache: cache, log_cache_bytes: bytes}
  end

  defp purge_expired_log_cache(state) do
    now = System.monotonic_time(:millisecond)

    {cache, bytes} =
      Enum.reduce(state.log_cache, {%{}, 0}, fn {key, entry}, {cache, bytes} ->
        if now - entry.stored_at < state.log_cache_ttl_ms do
          {Map.put(cache, key, entry), bytes + entry.size}
        else
          {cache, bytes}
        end
      end)

    %{state | log_cache: cache, log_cache_bytes: bytes}
  end

  defp invoke_query(query_fun, request, _state) when is_function(query_fun, 1),
    do: query_fun.(request)

  defp invoke_query(query_fun, request, state) when is_function(query_fun, 2),
    do: query_fun.(request, query_opts(state))

  defp invoke_query({module, function}, request, state),
    do: apply(module, function, [request, query_opts(state)])

  defp query_opts(state),
    do: [
      timeout: state.query_timeout_ms,
      socket_path: Application.get_env(:nix_swarm_web, :query_socket, "/run/nix-swarm/query.sock")
    ]

  defp stale_snapshot(%{last_good_snapshot: nil}, reason) do
    snapshot = ClusterSnapshot.empty(DateTime.utc_now(), stale?: true)
    %{snapshot | errors: [%{scope: "cluster_overview", reason: inspect(reason)}]}
  end

  defp stale_snapshot(%{last_good_snapshot: last_good}, reason) do
    error = %{scope: "cluster_overview", reason: inspect(reason)}
    %{last_good | stale?: true, errors: Enum.uniq(last_good.errors ++ [error])}
  end

  defp broadcast(state, snapshot) do
    Phoenix.PubSub.broadcast(state.pubsub_server, @snapshot_topic, {:cluster_snapshot, snapshot})
  catch
    :exit, _reason -> :ok
  end

  defp log_request(scope, target, lines) do
    lines = if is_integer(lines), do: lines, else: 200

    cond do
      lines not in 1..@max_log_lines ->
        {:error, :invalid_lines}

      scope in [:service, "service"] and valid_target?(target) ->
        target = to_string(target)
        {:ok, {:logs, target, lines}, {:service, target, lines}}

      scope in [:node, "node"] and valid_target?(target) ->
        target = to_string(target)
        {:ok, {:node_service_logs, target, lines}, {:node, target, lines}}

      scope in [:cluster, "cluster"] and valid_target?(target) ->
        target = to_string(target)
        {:ok, {:cluster_logs, target, lines}, {:cluster, target, lines}}

      true ->
        {:error, :invalid_log_scope}
    end
  end

  defp valid_target?(target) when is_binary(target), do: byte_size(target) in 1..255
  defp valid_target?(target) when is_atom(target), do: valid_target?(Atom.to_string(target))
  defp valid_target?(_), do: false

  defp schedule_next(state, delay) do
    cancel_timer(state.timer_ref)
    poll_ref = make_ref()
    timer = Process.send_after(self(), {:poll, poll_ref}, delay)
    %{state | timer_ref: timer, poll_ref: poll_ref}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp bounded_interval(value) when is_integer(value),
    do: value |> max(@min_interval_ms) |> min(@max_interval_ms)

  defp bounded_interval(_), do: @default_interval_ms

  defp bounded_timeout(value) when is_integer(value) and value > 0, do: min(value, 60_000)
  defp bounded_timeout(_), do: @default_timeout_ms

  defp bounded_cache_value(value, _default, max_value)
       when is_integer(value) and value > 0,
       do: min(value, max_value)

  defp bounded_cache_value(_value, default, _max_value), do: default

  defp stale?(%{stale?: value}), do: value
  defp stale?(_), do: false

  defp default_status do
    %{
      stale?: false,
      in_flight?: false,
      last_good_at: nil,
      last_error: nil,
      consecutive_failures: 0,
      interval_ms: @default_interval_ms,
      metric_samples: 0
    }
  end

  defp call_if_started(name, request, default, timeout \\ 5_000) do
    if is_pid(Process.whereis(name)) do
      GenServer.call(name, request, timeout)
    else
      default
    end
  catch
    :exit, _reason -> default
  end

  defp default_query(request) do
    NixSwarmWeb.QueryClient.query(request,
      timeout: Application.get_env(:nix_swarm_web, :query_timeout_ms, @default_timeout_ms),
      socket_path: Application.get_env(:nix_swarm_web, :query_socket, "/run/nix-swarm/query.sock")
    )
  end
end
