defmodule Swarm.Executor do
  @moduledoc false

  @callback start_unit(String.t(), map()) :: :ok | {:error, term()}
  @callback stop_unit(String.t(), map()) :: :ok | {:error, term()}
  @callback restart_unit(String.t(), map()) :: :ok | {:error, term()}
  @callback unit_status(String.t(), map()) ::
              {:ok, :running | :stopped | :unknown} | {:error, term()}
  @callback unit_logs(String.t(), pos_integer(), map()) :: {:ok, String.t()} | {:error, term()}

  def start_unit(unit), do: dispatch(:start_unit, [unit])
  def stop_unit(unit), do: dispatch(:stop_unit, [unit])
  def restart_unit(unit), do: dispatch(:restart_unit, [unit])
  def unit_status(unit), do: dispatch(:unit_status, [unit])
  def unit_logs(unit, lines), do: dispatch(:unit_logs, [unit, lines])

  defp dispatch(function, args) do
    {module, config} = adapter()
    apply(module, function, args ++ [config])
  end

  defp adapter do
    executor_config = Swarm.Config.runtime().executor

    case executor_config.adapter do
      :systemd -> {Swarm.Executor.Systemd, executor_config}
      _ -> {Swarm.Executor.Fake, executor_config}
    end
  end
end
