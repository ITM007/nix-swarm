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

  test "rejects unsafe unit names before any remote command runs" do
    parent = self()

    command_fun = fn _executable, _args ->
      send(parent, {:remote_command, "unexpected invocation"})
      {"", 0}
    end

    for unit <- [
          "foo;rm",
          "../../etc/passwd",
          "--root=/etc",
          "foo bar",
          "demo@0.service; systemctl stop all"
        ] do
      assert {:error, :invalid_unit_name} =
               NixSwarm.ServiceRestart.run(
                 service: "demo",
                 units: [%{slot: 0, unit: unit, owner: :node_a}],
                 command_fun: command_fun
               )
    end

    refute_received {:remote_command, _message}
  end

  test "remote restarts validate every unit before issuing ssh commands" do
    parent = self()

    command_fun = fn _executable, args ->
      send(parent, {:remote_command, Enum.join(args, " ")})
      {"", 0}
    end

    assert {:ok, %{service: "demo", units: [unit]}} =
             NixSwarm.ServiceRestart.run(
               service: "demo",
               units: [
                 %{slot: 1, unit: "demo@1.service", owner: :node_a, deploy_host: "root@node-a"}
               ],
               command_fun: command_fun
             )

    assert unit.unit == "demo@1.service"

    messages =
      for _ <- 1..2 do
        receive do
          {:remote_command, message} -> message
        after
          200 -> flunk("expected two remote commands")
        end
      end
      |> Enum.join("\n")

    assert messages =~ "systemctl restart demo@1.service"
    assert messages =~ "systemctl is-active --quiet demo@1.service"
    refute messages =~ "demo@2.service"
  end
end
