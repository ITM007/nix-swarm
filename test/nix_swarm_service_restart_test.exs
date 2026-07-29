defmodule NixSwarmServiceRestartTest do
  use ExUnit.Case, async: true

  defmodule RecordingExecutor do
    def restart_unit(unit) do
      send(Process.get(:test_pid), {:restart, unit})
      :ok
    end

    def unit_status(unit) do
      send(Process.get(:test_pid), {:status, unit})
      {:ok, :running}
    end
  end

  test "restarts observed units in slot order and verifies each one" do
    Process.put(:test_pid, self())

    units = [
      %{slot: 2, unit: "demo@2.service", owner: :node_b},
      %{slot: 0, unit: "demo@0.service", owner: :node_a},
      %{slot: 1, unit: "demo@1.service", owner: :node_a}
    ]

    expected = [Enum.at(units, 1), Enum.at(units, 2), Enum.at(units, 0)]

    assert {:ok, %{service: "demo", units: ^expected}} =
             NixSwarm.ServiceRestart.run(
               service: "demo",
               units: units,
               executor: RecordingExecutor
             )

    assert_received {:restart, "demo@2.service"}
    assert_received {:status, "demo@2.service"}
    assert_received {:restart, "demo@0.service"}
    assert_received {:status, "demo@0.service"}
    assert_received {:restart, "demo@1.service"}
    assert_received {:status, "demo@1.service"}
  end
end
