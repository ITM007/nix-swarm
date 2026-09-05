defmodule NixSwarmWeb.QueryBroker do
  @moduledoc """
  One supervised, cached query loop for all web consumers.

  LiveViews subscribe to the `cluster:snapshot` PubSub topic and never open the
  query socket themselves. A poll is executed by this server, so a slow query
  cannot create a second poll or a per-browser request storm.
  """

  use GenServer

  alias NixSwarmWeb.{ClusterSnapshot, MetricHistory}

  @snapshot_topic "cluster:snapshot"
  @default_interval_ms 5_000
  @min_interval_ms 1_000
  @max_interval_ms 60_000
  @default_timeout_ms 15_000
  @max_log_lines 1_000

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
          metric_history: MetricHistory.t(),
          log_cache: map()
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
    do: call_if_started(name, :refresh, {:error, :broker_unavailable})

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

    state = %{
      query_fun: query_fun,
      query_timeout_ms:
        bounded_timeout(Keyword.get(opts, :query_timeout_ms, @default_timeout_ms)),
      interval_ms: interval_ms,
      pubsub_server: pubsub_server,
      current_snapshot: nil,
      last_good_snapshot: nil,
      last_good_at: nil,
      last_error: nil,
      consecutive_failures: 0,
      in_flight?: false,
      timer_ref: nil,
      metric_history: MetricHistory.new(120),
      log_cache: %{}
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

  def handle_call(:refresh, _from, state) do
    {reply, state} = refresh_state(state)
    {:reply, reply, schedule_next(state, state.interval_ms)}
  end

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

  def handle_call({:logs, scope, target, lines}, _from, state) do
    with {:ok, request, key} <- log_request(scope, target, lines) do
      case Map.fetch(state.log_cache, key) do
        {:ok, response} ->
          {:reply, response, state}

        :error ->
          {response, state} = execute_log(state, request, key)
          {:reply, response, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:poll, timer_ref}, %{timer_ref: timer_ref} = state) do
    {_, state} = refresh_state(%{state | timer_ref: nil})
    {:noreply, schedule_next(state, state.interval_ms)}
  end

  def handle_info({:poll, _stale_timer_ref}, state), do: {:noreply, state}

  def handle_info(:poll, state) do
    {_, state} = refresh_state(%{state | timer_ref: nil})
    {:noreply, schedule_next(state, state.interval_ms)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)
    :ok
  end

  defp refresh_state(state) do
    state = %{state | in_flight?: true}

    case execute_query(state, :cluster_overview) do
      {:ok, payload} ->
        captured_at = DateTime.utc_now()
        snapshot = ClusterSnapshot.normalize(payload, captured_at: captured_at)
        previous = List.last(MetricHistory.samples(state.metric_history))

        delta =
          if previous,
            do: MetricHistory.delta(previous, snapshot),
            else: %{valid?: false, elapsed_ms: 0, cpu: nil, network: nil}

        snapshot = put_in(snapshot, [:metrics, :rates], delta)
        history = MetricHistory.push(state.metric_history, snapshot)

        state = %{
          state
          | current_snapshot: snapshot,
            last_good_snapshot: snapshot,
            last_good_at: captured_at,
            last_error: nil,
            consecutive_failures: 0,
            in_flight?: false,
            metric_history: history,
            log_cache: %{}
        }

        broadcast(state, snapshot)
        {{:ok, snapshot}, state}

      {:error, reason} ->
        snapshot = stale_snapshot(state, reason)

        state = %{
          state
          | current_snapshot: snapshot,
            last_error: reason,
            consecutive_failures: state.consecutive_failures + 1,
            in_flight?: false
        }

        broadcast(state, snapshot)
        {{:error, reason}, state}
    end
  end

  defp execute_query(state, request) do
    task = Task.async(fn -> invoke_query(state.query_fun, request, state) end)

    case Task.yield(task, state.query_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, payload}} -> {:ok, payload}
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
      other -> {:error, other}
    end
  end

  defp execute_log(state, request, key) do
    response = execute_query(state, request)

    state =
      if match?({:ok, _}, response),
        do: %{state | log_cache: Map.put(state.log_cache, key, response)},
        else: state

    {response, state}
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
    timer_ref = make_ref()
    timer = Process.send_after(self(), {:poll, timer_ref}, delay)
    %{state | timer_ref: timer}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp bounded_interval(value) when is_integer(value),
    do: value |> max(@min_interval_ms) |> min(@max_interval_ms)

  defp bounded_interval(_), do: @default_interval_ms

  defp bounded_timeout(value) when is_integer(value) and value > 0, do: min(value, 60_000)
  defp bounded_timeout(_), do: @default_timeout_ms

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

  defp call_if_started(name, request, default) do
    if is_pid(Process.whereis(name)) do
      GenServer.call(name, request)
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
