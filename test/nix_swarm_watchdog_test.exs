defmodule NixSwarmWatchdogTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-watchdog-#{System.unique_integer([:positive])}")

    executable = Path.join(root, "systemd-notify")
    log = Path.join(root, "notify.log")
    File.mkdir_p!(root)
    File.write!(executable, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$NIX_SWARM_NOTIFY_LOG\"\n")
    File.chmod!(executable, 0o700)

    previous =
      for name <- [
            "NOTIFY_SOCKET",
            "WATCHDOG_USEC",
            "NIX_SWARM_SYSTEMD_NOTIFY",
            "NIX_SWARM_NOTIFY_LOG"
          ],
          into: %{},
          do: {name, System.get_env(name)}

    System.put_env("NOTIFY_SOCKET", "/run/systemd/notify")
    System.put_env("WATCHDOG_USEC", "2000000")
    System.put_env("NIX_SWARM_SYSTEMD_NOTIFY", executable)
    System.put_env("NIX_SWARM_NOTIFY_LOG", log)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(root)
    end)

    {:ok, log: log}
  end

  test "announces readiness, watchdog health, and shutdown", %{log: log} do
    assert {:ok, pid} = NixSwarm.Watchdog.start_link()
    send(pid, :ping)

    wait_until(fn -> File.exists?(log) and File.read!(log) =~ "WATCHDOG=1" end)
    GenServer.stop(pid)

    output = File.read!(log)
    assert output =~ "--ready"
    assert output =~ "WATCHDOG=1"
    assert output =~ "--stopping"
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition not met before timeout")
end
