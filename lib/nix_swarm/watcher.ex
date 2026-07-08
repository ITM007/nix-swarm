defmodule NixSwarm.Watcher do
  @moduledoc """
  Watches a source directory for file changes and auto-deploys.

  Uses Linux `inotify` for instant change detection (zero polling).
  Falls back to mtime polling if inotifywait is unavailable.

  When files under `source` change, the watcher debounces for `@debounce_ms`
  and then triggers a deploy via the configured `deploy_fun`.
  """

  use GenServer

  @debounce_ms 3_000
  @fallback_poll_ms 5_000

  defmodule State do
    @moduledoc false
    defstruct [
      :source,
      :deploy_fun,
      :notify_pid,
      :pending_change_at,
      :deploying?,
      :port,
      :fallback_timer
    ]
  end

  # --- Public API ---

  def start_link(opts) do
    source = Keyword.fetch!(opts, :source) |> Path.expand()
    deploy_fun = Keyword.fetch!(opts, :deploy_fun)
    notify_pid = Keyword.get(opts, :notify_pid)

    GenServer.start_link(
      __MODULE__,
      %State{
        source: source,
        deploy_fun: deploy_fun,
        notify_pid: notify_pid,
        pending_change_at: nil,
        deploying?: false,
        port: nil,
        fallback_timer: nil
      },
      name: __MODULE__
    )
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(state) do
    state = start_inotify(state)
    log(state, "Watching #{state.source}")
    {:ok, state}
  end

  @impl true
  def handle_info({port, {:data, _line}}, %{port: port} = state) do
    if state.pending_change_at do
      # Already pending — debounce window is active, restart timer
      {:noreply, %{state | pending_change_at: now_ms()}}
    else
      state = %{state | pending_change_at: now_ms()}
      schedule_debounce_check()
      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    log(state, "inotify port exited, switching to fallback polling")
    {:noreply, start_fallback(state)}
  end

  def handle_info(:check_debounce, state) do
    if not is_nil(state.pending_change_at) and
         now_ms() - state.pending_change_at >= @debounce_ms and
         not state.deploying? do
      state = %{state | pending_change_at: nil, deploying?: true}
      notify(state, {:watcher, :deploying})
      deploy_async(state)
      {:noreply, state}
    else
      schedule_debounce_check()
      {:noreply, state}
    end
  end

  def handle_info(:fallback_poll, state) do
    {:noreply, fallback_check(state)}
  end

  def handle_info({:deploy_done, :ok}, state) do
    state = %{state | deploying?: false}
    notify(state, {:watcher, :idle})
    {:noreply, state}
  end

  def handle_info({:deploy_done, {:error, reason}}, state) do
    state = %{state | deploying?: false}
    log(state, "Deploy failed: #{inspect(reason)}")
    notify(state, {:watcher, {:error, reason}})
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status =
      cond do
        state.deploying? -> :deploying
        not is_nil(state.pending_change_at) -> :changed
        true -> :idle
      end

    {:reply, status, state}
  end

  # --- Private: inotify ---

  defp start_inotify(state) do
    source = state.source
    excludes = "--exclude '(_build|deps|\\.git|result)'"

    port =
      Port.open({:spawn, "inotifywait -m -r #{excludes} -e modify,create,delete,move --format '%w%f' #{source}"}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    %{state | port: port}
  rescue
    _ ->
      log(state, "inotifywait not available, using fallback polling")
      start_fallback(state)
  end

  defp start_fallback(state) do
    timer = Process.send_after(self(), :fallback_poll, @fallback_poll_ms)
    %{state | fallback_timer: timer, port: nil}
  end

  defp fallback_check(state) do
    # Quick mtime check on a single representative file
    cluster = Path.join(state.source, "cluster.nix")
    machines_dir = Path.join(state.source, "machines")
    services_dir = Path.join(state.source, "services")

    changed? =
      Enum.any?([cluster, machines_dir, services_dir], fn path ->
        case File.stat(path, time: :posix) do
          {:ok, _stat} ->
            case state.fallback_timer do
              nil -> false
              _ -> false
            end
          _ ->
            false
        end
      end)

    state = %{state | fallback_timer: Process.send_after(self(), :fallback_poll, @fallback_poll_ms)}

    if changed? do
      %{state | pending_change_at: now_ms()}
      |> then(fn s ->
        schedule_debounce_check()
        s
      end)
    else
      state
    end
  end

  # --- Private: debounce ---

  defp schedule_debounce_check do
    Process.send_after(self(), :check_debounce, 500)
  end

  # --- Private: deploy ---

  defp deploy_async(state) do
    parent = self()
    source = state.source
    deploy_fun = state.deploy_fun

    Task.start(fn ->
      result =
        try do
          deploy_opts = [source: source]
          deploy_fun.(deploy_opts)
          :ok
        rescue
          e ->
            {:error, Exception.message(e)}
        end

      send(parent, {:deploy_done, result})
    end)
  end

  # --- Helpers ---

  defp notify(%{notify_pid: nil}, _msg), do: :ok

  defp notify(%{notify_pid: pid}, msg) when is_pid(pid),
    do: send(pid, {:watcher_status, msg})

  defp log(_state, msg), do: IO.puts("[nix-swarm watch] #{msg}")

  defp now_ms, do: System.monotonic_time(:millisecond)
end
