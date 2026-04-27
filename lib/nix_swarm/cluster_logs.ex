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
    |> String.split("\n", trim: true)
    |> Enum.reject(&benign_line?/1)
    |> Enum.join("\n")
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
