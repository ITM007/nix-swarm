defmodule Swarm.Executor.Systemd do
  @moduledoc false

  def start_unit(unit, _config) do
    reset_failed(unit)
    systemctl(["start", unit])
  end

  def stop_unit(unit, _config), do: systemctl(["stop", unit])

  def restart_unit(unit, _config) do
    reset_failed(unit)
    systemctl(["restart", unit])
  end

  def unit_status(unit, _config) do
    case System.cmd("systemctl", ["is-active", unit], stderr_to_stdout: true) do
      {"active\n", 0} -> {:ok, :running}
      {_, 0} -> {:ok, :running}
      _ -> {:ok, :stopped}
    end
  end

  def unit_logs(unit, lines, _config) do
    case System.cmd("journalctl", ["-u", unit, "-n", Integer.to_string(lines), "--no-pager"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, status} -> {:error, {:journalctl_failed, status, output}}
    end
  end

  defp systemctl(args) do
    case System.cmd("systemctl", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:systemctl_failed, status, output}}
    end
  end

  defp reset_failed(unit) do
    System.cmd("systemctl", ["reset-failed", unit], stderr_to_stdout: true)
    :ok
  end
end
