defmodule NixSwarm.ClusterLogs do
  @moduledoc false

  @benign_fragments [
    "epmd: got partial packet only",
    "genserver :memsup terminating",
    "genserver :disksup terminating",
    ":alarm_handler: {:set, {:system_memory_high_water",
    ":alarm_handler: {:clear, :system_memory_high_water",
    "{:port_died, :normal}",
    "error writing to pipe: broken pipe",
    "last message: {:exit, #pid<",
    ~s(state: [{~c"timeout"),
    ~s(state: [{~c"os"),
    "state: [data:",
    "sigterm received - shutting down"
  ]

  def sanitize(output) do
    output
    |> to_string()
    |> terminal_safe()
    |> String.split("\n", trim: true)
    |> Enum.reject(&benign_line?/1)
    |> Enum.join("\n")
  end

  @doc "Removes terminal escape sequences and control characters from untrusted output."
  def terminal_safe(output) do
    output
    |> to_string()
    |> String.replace(~r/\x1B\][^\x07]*(?:\x07|\x1B\\)/, "")
    |> String.replace(~r/\x1B\[[0-?]*[ -\/]*[@-~]/, "")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1A\x1C-\x1F\x7F]/, "")
  end

  def benign_line?(line) do
    lowered = String.downcase(line)

    Enum.any?(@benign_fragments, &String.contains?(lowered, &1)) or
      benign_cluster_rejoin_line?(lowered)
  end

  defp benign_cluster_rejoin_line?(line) do
    String.contains?(line, "'global' at") and
      ((String.contains?(line, "requested disconnect from node") and
          String.contains?(line, "overlapping partitions")) or
         String.contains?(line, "failed to connect to"))
  end
end
