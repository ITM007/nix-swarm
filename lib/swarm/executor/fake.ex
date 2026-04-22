defmodule Swarm.Executor.Fake do
  @moduledoc false

  def start_unit(unit, config) do
    File.mkdir_p!(node_root(config))
    File.write!(state_file(unit, config), "running\n")
    append_log(unit, "start")
    :ok
  end

  def stop_unit(unit, config) do
    File.mkdir_p!(node_root(config))
    File.write!(state_file(unit, config), "stopped\n")
    append_log(unit, "stop")
    :ok
  end

  def restart_unit(unit, config) do
    File.mkdir_p!(node_root(config))
    File.write!(state_file(unit, config), "running\n")
    append_log(unit, "restart")
    :ok
  end

  def unit_status(unit, config) do
    case File.read(state_file(unit, config)) do
      {:ok, content} ->
        case String.trim(content) do
          "running" -> {:ok, :running}
          "stopped" -> {:ok, :stopped}
          _ -> {:ok, :unknown}
        end

      {:error, :enoent} ->
        {:ok, :stopped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def unit_logs(unit, lines, config) do
    case File.read(log_file(unit, config)) do
      {:ok, content} ->
        output =
          content
          |> String.split("\n", trim: true)
          |> Enum.take(-lines)
          |> Enum.join("\n")

        {:ok, output}

      {:error, :enoent} ->
        {:ok, ""}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_log(unit, action) do
    File.mkdir_p!(node_root(Swarm.Config.runtime().executor))

    File.write!(
      log_file(unit, Swarm.Config.runtime().executor),
      "#{DateTime.utc_now() |> DateTime.to_iso8601()} #{action}\n",
      [:append]
    )
  end

  defp state_file(unit, config), do: Path.join(node_root(config), "#{unit}.state")
  defp log_file(unit, config), do: Path.join(node_root(config), "#{unit}.log")

  defp node_root(config) do
    Path.join(config.root, sanitize(Node.self()))
  end

  defp sanitize(node) do
    node
    |> Atom.to_string()
    |> String.replace(~r/[^a-zA-Z0-9_.-]/, "_")
  end
end
