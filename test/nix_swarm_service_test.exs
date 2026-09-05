defmodule NixSwarmServiceTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Service

  defp normalize(raw), do: raw |> Map.put(:name, "demo") |> Service.normalize()

  test "parses a full state block" do
    service =
      normalize(%{
        state: %{
          dirs: ["/var/lib/demo"],
          backup: %{schedule: "daily", target: "ssh://borg@backup/./demo"},
          restore: "borg-latest",
          autoHeal: true,
          healGraceSec: 300
        }
      })

    assert service.state == %{
             dirs: ["/var/lib/demo"],
             backup: %{schedule: "daily", target: "ssh://borg@backup/./demo"},
             restore: "borg-latest",
             auto_heal: true,
             heal_grace_sec: 300
           }

    assert Service.stateful?(service)
    assert Service.awaiting_restore?(service)
    assert Service.state_dirs(service) == ["/var/lib/demo"]
  end

  test "defaults: no backup block means restore none and no auto heal" do
    service = normalize(%{state: %{dirs: ["/var/lib/demo"]}})

    assert service.state == %{
             dirs: ["/var/lib/demo"],
             backup: nil,
             restore: "none",
             auto_heal: false,
             heal_grace_sec: 600
           }

    assert Service.stateful?(service)
    refute Service.awaiting_restore?(service)
  end

  test "restore defaults to borg-latest when a backup block is present" do
    service =
      normalize(%{
        state: %{dirs: ["/var/lib/demo"], backup: %{target: "ssh://borg@backup/./demo"}}
      })

    assert service.state.restore == "borg-latest"
    assert service.state.backup.schedule == "hourly"
  end

  test "snake_case and camelCase keys are equivalent" do
    snake = normalize(%{state: %{dirs: ["/s"], auto_heal: true, heal_grace_sec: 42}})
    camel = normalize(%{state: %{dirs: ["/s"], autoHeal: true, healGraceSec: 42}})

    assert snake.state == camel.state
  end

  test "restore may be nested under onPlacement for Docker-Swarm-style configs" do
    service =
      normalize(%{
        state: %{
          dirs: ["/var/lib/demo"],
          backup: %{target: "ssh://borg@backup/./demo"},
          onPlacement: %{restore: "borg-latest"}
        }
      })

    assert service.state.restore == "borg-latest"
  end

  test "on_placement without restore falls back to the backup default" do
    service =
      normalize(%{
        state: %{
          dirs: ["/var/lib/demo"],
          backup: %{target: "ssh://borg@backup/./demo"},
          onPlacement: %{}
        }
      })

    assert service.state.restore == "borg-latest"
  end

  test "no state block leaves state nil and helpers return false/empty" do
    service = normalize(%{replicas: 2})

    assert service.state == nil
    refute Service.stateful?(service)
    refute Service.awaiting_restore?(service)
    assert Service.state_dirs(service) == []
  end

  test "rejects a non-list dirs value" do
    assert_raise ArgumentError, ~r/state\.dirs must be a list of absolute paths/, fn ->
      normalize(%{state: %{dirs: "/var/lib/demo"}})
    end
  end

  test "rejects an empty dirs list" do
    assert_raise ArgumentError, ~r/state\.dirs must not be empty/, fn ->
      normalize(%{state: %{dirs: []}})
    end
  end

  test "rejects relative state dirs" do
    assert_raise ArgumentError, ~r/must be absolute paths/, fn ->
      normalize(%{state: %{dirs: ["var/lib/demo"]}})
    end
  end

  test "rejects unknown state keys loudly" do
    assert_raise ArgumentError, ~r/unsupported key\(s\): restoreMode/, fn ->
      normalize(%{state: %{dirs: ["/var/lib/demo"], restoreMode: "swarm"}})
    end
  end

  test "rejects a backup block without a target" do
    assert_raise ArgumentError, ~r/state\.backup\.target is required/, fn ->
      normalize(%{state: %{dirs: ["/var/lib/demo"], backup: %{schedule: "hourly"}}})
    end
  end

  test "rejects an unknown restore kind" do
    assert_raise ArgumentError, ~r/state\.restore must be one of/, fn ->
      normalize(%{state: %{dirs: ["/var/lib/demo"], restore: "copy-on-write"}})
    end
  end

  test "rejects restore that requires a backup when none is declared" do
    assert_raise ArgumentError, ~r/requires a state\.backup block/, fn ->
      normalize(%{state: %{dirs: ["/var/lib/demo"], restore: "borg-latest"}})
    end
  end

  test "rejects a non-map state value" do
    assert_raise ArgumentError, ~r/state must be a map/, fn ->
      normalize(%{state: "persistent"})
    end
  end

  test "coerces dirs entries to strings" do
    service = normalize(%{state: %{dirs: [:"/var/lib/demo"]}})
    assert service.state.dirs == ["/var/lib/demo"]
  end
end
