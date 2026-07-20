defmodule NixSwarm.RPC do
  @moduledoc """
  Bounded, normalized RPC helpers built on OTP's `:erpc` implementation.
  """

  def call(node, module, function, args, timeout \\ NixSwarm.rpc_timeout_ms()) do
    if node == Node.self() do
      local_call(module, function, args)
    else
      remote_call(node, module, function, args, timeout)
    end
  end

  def call!(node, module, function, args, timeout \\ NixSwarm.rpc_timeout_ms()) do
    case call(node, module, function, args, timeout) do
      {:ok, result} -> result
      {:error, reason} -> raise RuntimeError, "RPC to #{node} failed: #{inspect(reason)}"
    end
  end

  def cast(node, module, function, args) do
    if node == Node.self() do
      _ = spawn(fn -> apply(module, function, args) end)
      :ok
    else
      _request_id = :erpc.cast(node, module, function, args)
      :ok
    end
  catch
    class, reason -> {:error, {class, reason}}
  end

  def multicall(nodes, module, function, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, NixSwarm.rpc_timeout_ms())
    max_concurrency = Keyword.get(opts, :max_concurrency, max(length(nodes), 1))

    Task.Supervisor.async_stream_nolink(
      NixSwarm.TaskSupervisor,
      nodes,
      fn node -> {node, call(node, module, function, args, timeout)} end,
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: timeout + 250,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:unknown, {:error, {:task_exit, reason}}}
    end)
  end

  @doc false
  def legacy_call(node, module, function, args, timeout) do
    case call(node, module, function, args, timeout) do
      {:ok, result} -> result
      {:error, reason} -> {:badrpc, reason}
    end
  end

  defp local_call(module, function, args) do
    {:ok, apply(module, function, args)}
  rescue
    error -> {:error, {:exception, error, __STACKTRACE__}}
  catch
    class, reason -> {:error, {class, reason}}
  end

  defp remote_call(node, module, function, args, timeout) do
    NixSwarm.Telemetry.span(
      [:nix_swarm, :rpc],
      %{node: node, module: module, function: function, arity: length(args)},
      fn ->
        try do
          {:ok, :erpc.call(node, module, function, args, timeout)}
        catch
          class, reason -> {:error, {class, reason}}
        end
      end
    )
  end
end
