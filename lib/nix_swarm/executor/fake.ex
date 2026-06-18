defmodule NixSwarm.Executor.Fake do
  @moduledoc false

  def start_unit(unit, config) do
    transition_unit(unit, "start", "starting", "running", config)
  end

  def stop_unit(unit, config) do
    with :ok <- ensure_node_root(config),
         :ok <- File.write(state_file(unit, config), "stopped\n"),
         :ok <- append_log(unit, "stop", config) do
      :ok
    end
  end

  def restart_unit(unit, config) do
    transition_unit(unit, "restart", "restarting", "running", config)
  end

  def unit_status(unit, config) do
    case File.read(state_file(unit, config)) do
      {:ok, content} ->
        case String.trim(content) do
          "running" -> {:ok, :running}
          "starting" -> {:ok, :starting}
          "restarting" -> {:ok, :restarting}
          "stopping" -> {:ok, :stopping}
          "stopped" -> {:ok, :stopped}
          "failed" -> {:ok, :failed}
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

  def unit_metrics(unit, config) do
    multiplier = rem(:erlang.phash2(unit, 9_973), 9) + 1

    case unit_status(unit, config) do
      {:ok, :running} ->
        counter = abs(System.monotonic_time(:millisecond)) * multiplier

        started_at_ns =
          System.system_time(:nanosecond) - multiplier * 30_000_000_000

        %{
          cpu: %{usage_ns: counter * 1_000_000},
          memory: %{used: multiplier * 64 * 1024 * 1024},
          disk: %{used: multiplier * 256 * 1024 * 1024},
          network: %{counter: counter * 16_384},
          started_at_ns: started_at_ns
        }

      _ ->
        default_metrics()
    end
  end

  def restart_host(config) do
    append_machine_log("restart", config)
  end

  def shutdown_host(config) do
    append_machine_log("shutdown", config)
  end

  defp transition_unit(unit, action, transient_state, final_state, config) do
    with :ok <- ensure_node_root(config),
         :ok <- File.write(state_file(unit, config), transient_state <> "\n"),
         :ok <- append_log(unit, action, config),
         :ok <- File.write(state_file(unit, config), final_state <> "\n") do
      :ok
    end
  end

  defp append_log(unit, action, config) do
    with :ok <- ensure_node_root(config) do
      File.write(
        log_file(unit, config),
        "#{DateTime.utc_now() |> DateTime.to_iso8601()} #{action}\n",
        [:append]
      )
    end
  end

  defp append_machine_log(action, config) do
    with :ok <- ensure_node_root(config) do
      File.write(
        machine_log_file(config),
        "#{DateTime.utc_now() |> DateTime.to_iso8601()} #{action}\n",
        [:append]
      )
    end
  end

  defp ensure_node_root(config) do
    File.mkdir_p(node_root(config))
  end

  defp state_file(unit, config), do: Path.join(node_root(config), "#{unit}.state")
  defp log_file(unit, config), do: Path.join(node_root(config), "#{unit}.log")
  defp machine_log_file(config), do: Path.join(node_root(config), "machine.log")

  defp default_metrics,
    do: %{
      cpu: %{usage_ns: 0},
      memory: %{used: 0},
      disk: %{used: 0},
      network: %{counter: 0},
      started_at_ns: 0
    }

  @doc """
  Sanitize a node name (atom) into a safe directory name by replacing
  non-alphanumeric characters with underscores.
  """
  def sanitize_node_name(node) do
    node
    |> Atom.to_string()
    |> String.replace(~r/[^a-zA-Z0-9_.-]/, "_")
  end

  defp node_root(config) do
    Path.join(config.root, sanitize_node_name(Node.self()))
  end
end
