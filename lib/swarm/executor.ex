defmodule Swarm.Executor do
  @moduledoc false

  @type unit_state ::
          :running | :starting | :restarting | :stopping | :stopped | :failed | :unknown

  @callback start_unit(String.t(), map()) :: :ok | {:error, term()}
  @callback stop_unit(String.t(), map()) :: :ok | {:error, term()}
  @callback restart_unit(String.t(), map()) :: :ok | {:error, term()}
  @callback unit_status(String.t(), map()) :: {:ok, unit_state()} | {:error, term()}
  @callback unit_logs(String.t(), pos_integer(), map()) :: {:ok, String.t()} | {:error, term()}
  @callback unit_metrics(String.t(), map()) :: map()
  @callback restart_host(map()) :: :ok | {:error, term()}
  @callback shutdown_host(map()) :: :ok | {:error, term()}

  # systemd unit names: alphanumerics, dot, dash, underscore, @, colon (for templated units),
  # plus a required ".service" suffix in practice. We accept a permissive but strictly safe set
  # and explicitly reject any leading dash (which would be parsed as a CLI flag by systemctl /
  # journalctl) or a path traversal sequence like "..".
  @unit_name_re ~r/\A[A-Za-z0-9_][A-Za-z0-9._@:\-]{0,254}\z/

  def start_unit(unit), do: dispatch(:start_unit, unit, [unit])
  def stop_unit(unit), do: dispatch(:stop_unit, unit, [unit])
  def restart_unit(unit), do: dispatch(:restart_unit, unit, [unit])
  def unit_status(unit), do: dispatch(:unit_status, unit, [unit])
  def unit_logs(unit, lines), do: dispatch(:unit_logs, unit, [unit, lines])
  def unit_metrics(unit), do: dispatch(:unit_metrics, unit, [unit])
  def restart_host, do: dispatch_host_action(:restart_host)
  def shutdown_host, do: dispatch_host_action(:shutdown_host)

  @doc """
  Returns `:ok` when `unit` is a safe systemd unit name and `{:error, :invalid_unit_name}`
  otherwise. Used to prevent argument injection on `systemctl`/`journalctl` and to block
  path traversal in the file-backed Fake executor.
  """
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

      {:error, _} = err ->
        case function do
          :unit_metrics -> default_metrics()
          :unit_status -> {:ok, :unknown}
          :unit_logs -> {:error, :invalid_unit_name}
          _ -> err
        end
    end
  end

  defp dispatch_host_action(function) do
    {module, config} = adapter()
    apply(module, function, [config])
  end

  defp default_metrics do
    %{
      cpu: %{usage_ns: 0},
      memory: %{used: 0},
      disk: %{counter: 0},
      network: %{counter: 0},
      started_at_ns: 0
    }
  end

  defp adapter do
    executor_config = Swarm.Config.runtime().executor

    case executor_config.adapter do
      :systemd -> {Swarm.Executor.Systemd, executor_config}
      _ -> {Swarm.Executor.Fake, executor_config}
    end
  end
end
