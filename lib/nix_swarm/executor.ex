defmodule NixSwarm.Executor do
  @moduledoc """
  Delegates systemctl operations to the Executor.Server GenServer.

  Falls back to Executor.Systemd for out-of-band calls (tests, bootstrap).
  """

  def start_unit(unit, _config \\ nil),
    do: delegate(:start_unit, [unit])

  def stop_unit(unit, _config \\ nil),
    do: delegate(:stop_unit, [unit])

  def restart_unit(unit, _config \\ nil),
    do: delegate(:restart_unit, [unit])

  def unit_status(unit, _config \\ nil),
    do: delegate(:unit_status, [unit])

  def batch_unit_status(units),
    do: delegate(:batch_unit_status, [units])

  def unit_logs(unit, lines, _config \\ nil),
    do: delegate(:unit_logs, [unit, lines])

  def unit_metrics(unit, _config \\ nil),
    do: delegate(:unit_metrics, [unit])

  def restart_host(_config \\ nil),
    do: delegate(:restart_host, [])

  def shutdown_host(_config \\ nil),
    do: delegate(:shutdown_host, [])

  defp delegate(fun, args) do
    case Process.whereis(NixSwarm.Executor.Server) do
      nil ->
        try do
          apply(NixSwarm.Executor.Systemd, fun, args ++ [%{}])
        rescue
          _ ->
            if fun == :batch_unit_status do
              # Fallback: individual status calls
              Map.new(args |> hd(), &{&1, apply(NixSwarm.Executor.Systemd, :unit_status, [&1, %{}]) |> elem(1)})
            else
              reraise __MODULE__, [], __STACKTRACE__
            end
        end

      _pid ->
        apply(NixSwarm.Executor.Server, fun, args)
    end
  end
end
