defmodule NixSwarm.Telemetry do
  @moduledoc """
  Emits :telemetry events when available (OTP 24+). No-op otherwise.
  """

  @telemetry_available Code.ensure_loaded?(:telemetry)

  def reconcile_start, do: emit([:nix_swarm, :reconcile, :start], %{}, %{})
  def reconcile_stop(owned_units, start_time) do
    duration = System.monotonic_time(:microsecond) - start_time
    emit([:nix_swarm, :reconcile, :stop], %{duration_us: duration}, %{owned_units: owned_units})
  end
  def rpc_call(node, function, start_time) do
    duration = System.monotonic_time(:microsecond) - start_time
    emit([:nix_swarm, :rpc, :call], %{duration_us: duration}, %{node: node, function: function})
  end
  def systemctl(unit, action, start_time) do
    duration = System.monotonic_time(:microsecond) - start_time
    emit([:nix_swarm, :systemctl, :call], %{duration_us: duration}, %{unit: unit, action: action})
  end
  def deploy_start, do: emit([:nix_swarm, :deploy, :start], %{}, %{})
  def deploy_stop(start_time) do
    duration = System.monotonic_time(:microsecond) - start_time
    emit([:nix_swarm, :deploy, :stop], %{duration_us: duration}, %{})
  end

  # Use apply/3 to avoid compile-time warnings when :telemetry isn't available
  defp emit(event, measurements, metadata) do
    if @telemetry_available do
      _ = apply(:telemetry, :execute, [event, measurements, metadata])
    end
    :ok
  end
end
