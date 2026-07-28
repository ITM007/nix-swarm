defmodule NixSwarm.Telemetry do
  @moduledoc """
  Stable telemetry event helpers for runtime operations.

  Every span emits `:start`, `:stop`, and (when raised) `:exception` events
  using the supplied event prefix. Stop events include native-unit duration.
  """

  def span(event_prefix, metadata, fun) when is_list(event_prefix) and is_function(fun, 0) do
    :telemetry.span(event_prefix, metadata, fn ->
      result = fun.()
      {result, Map.put(metadata, :outcome, outcome(result))}
    end)
  end

  def execute(event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(event, measurements, metadata)
  end

  defp outcome({:error, _reason}), do: :error
  defp outcome({:ok, _result}), do: :ok
  defp outcome(_result), do: :ok
end
