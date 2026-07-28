defmodule NixSwarm.Executor do
  @moduledoc """
  Validated adapter boundary for local systemd operations.

  The runtime selects either the real systemd adapter or the file-backed fake
  adapter from the immutable cluster configuration. Every unit operation is
  validated before it reaches a command or filesystem boundary.
  """

  @type unit_state ::
          :running | :starting | :restarting | :stopping | :stopped | :failed | :unknown

  @callback start_unit(String.t(), map()) :: :ok | {:error, term()}
  @callback stop_unit(String.t(), map()) :: :ok | {:error, term()}
  @callback restart_unit(String.t(), map()) :: :ok | {:error, term()}
  @callback unit_status(String.t(), map()) :: {:ok, unit_state()} | {:error, term()}
  @callback batch_unit_status([String.t()], map()) ::
              %{optional(String.t()) => {:ok, unit_state()} | {:error, term()}}
  @callback unit_logs(String.t(), pos_integer(), map()) :: {:ok, String.t()} | {:error, term()}
  @callback unit_metrics(String.t(), map()) :: map()
  @callback unit_cpu_usage(String.t(), map()) :: non_neg_integer()

  @unit_name_re ~r/\A[A-Za-z0-9_][A-Za-z0-9._@:\-]{0,254}\z/

  @spec start_unit(String.t()) :: :ok | {:error, term()}
  def start_unit(unit), do: dispatch(:start_unit, unit, [unit])

  @spec stop_unit(String.t()) :: :ok | {:error, term()}
  def stop_unit(unit), do: dispatch(:stop_unit, unit, [unit])

  @spec restart_unit(String.t()) :: :ok | {:error, term()}
  def restart_unit(unit), do: dispatch(:restart_unit, unit, [unit])

  @spec unit_status(String.t()) :: {:ok, unit_state()} | {:error, term()}
  def unit_status(unit), do: dispatch(:unit_status, unit, [unit])

  @spec batch_unit_status([String.t()]) :: %{
          optional(String.t()) => {:ok, unit_state()} | {:error, term()}
        }
  def batch_unit_status(units) when is_list(units) do
    {valid, invalid} = Enum.split_with(Enum.uniq(units), &(validate_unit_name(&1) == :ok))
    {module, config} = adapter()

    valid_statuses =
      if function_exported?(module, :batch_unit_status, 2) do
        module.batch_unit_status(valid, config)
      else
        Map.new(valid, &{&1, module.unit_status(&1, config)})
      end

    Enum.reduce(invalid, valid_statuses, &Map.put(&2, &1, {:ok, :unknown}))
  end

  @spec unit_logs(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def unit_logs(unit, lines), do: dispatch(:unit_logs, unit, [unit, lines])

  @spec unit_metrics(String.t()) :: map()
  def unit_metrics(unit), do: dispatch(:unit_metrics, unit, [unit])

  @spec unit_cpu_usage(String.t()) :: non_neg_integer()
  def unit_cpu_usage(unit), do: dispatch(:unit_cpu_usage, unit, [unit])

  @doc "Returns `:ok` only for a command-line-safe systemd unit name."
  @spec validate_unit_name(term()) :: :ok | {:error, :invalid_unit_name}
  def validate_unit_name(unit) when is_binary(unit) do
    cond do
      not Regex.match?(@unit_name_re, unit) -> {:error, :invalid_unit_name}
      String.contains?(unit, "..") -> {:error, :invalid_unit_name}
      true -> :ok
    end
  end

  def validate_unit_name(_), do: {:error, :invalid_unit_name}

  defp dispatch(function, unit, args) do
    case validate_unit_name(unit) do
      :ok ->
        {module, config} = adapter()
        apply(module, function, args ++ [config])

      {:error, _reason} = error ->
        invalid_unit_result(function, error)
    end
  end

  defp invalid_unit_result(:unit_metrics, _error), do: default_metrics()
  defp invalid_unit_result(:unit_cpu_usage, _error), do: 0
  defp invalid_unit_result(:unit_status, _error), do: {:ok, :unknown}
  defp invalid_unit_result(:unit_logs, _error), do: {:error, :invalid_unit_name}
  defp invalid_unit_result(_function, error), do: error

  defp adapter do
    runtime = NixSwarm.Config.runtime()
    executor_config = Map.put(runtime.executor, :command_timeout_ms, runtime.command_timeout_ms)

    case executor_config.adapter do
      :systemd -> {NixSwarm.Executor.Systemd, executor_config}
      _ -> {NixSwarm.Executor.Fake, executor_config}
    end
  end

  defp default_metrics do
    %{
      cpu: %{usage_ns: 0},
      memory: %{used: 0},
      disk: %{used: 0},
      network: %{counter: 0},
      started_at_ns: 0
    }
  end
end
