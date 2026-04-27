defmodule NixSwarmExecutorSystemdTest do
  use ExUnit.Case, async: false

  alias NixSwarm.Executor.Systemd

  test "unit_status maps transitional and failed systemd states" do
    with_fake_systemctl(
      """
      #!/bin/sh
      cat <<'EOF'
      ActiveState=activating
      SubState=auto-restart
      Result=success
      EOF
      """,
      fn ->
        assert {:ok, :restarting} = Systemd.unit_status("demo.service", %{})
      end
    )

    with_fake_systemctl(
      """
      #!/bin/sh
      cat <<'EOF'
      ActiveState=deactivating
      SubState=stop-sigterm
      Result=success
      EOF
      """,
      fn ->
        assert {:ok, :stopping} = Systemd.unit_status("demo.service", %{})
      end
    )

    with_fake_systemctl(
      """
      #!/bin/sh
      cat <<'EOF'
      ActiveState=failed
      SubState=failed
      Result=exit-code
      EOF
      """,
      fn ->
        assert {:ok, :failed} = Systemd.unit_status("demo.service", %{})
      end
    )
  end

  test "unit_metrics coerces non-numeric systemd placeholders to zero" do
    with_fake_systemctl(
      """
      #!/bin/sh
      cat <<'EOF'
      CPUUsageNSec=[no data]
      MemoryCurrent=[not set]
      IPIngressBytes=123
      IPEgressBytes=[no data]
      ActiveEnterTimestampUSec=[no data]
      StateDirectory=
      CacheDirectory=
      LogsDirectory=
      RuntimeDirectory=
      ConfigurationDirectory=
      RootDirectory=
      EOF
      """,
      fn ->
        metrics = Systemd.unit_metrics("demo.service", %{})

        assert metrics.cpu.usage_ns == 0
        assert metrics.memory.used == 0
        assert metrics.disk.used == 0
        assert metrics.network.counter == 123
        assert metrics.started_at_ns == 0
      end
    )
  end

  defp with_fake_systemctl(script, fun) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "nix-swarm-systemctl-#{System.unique_integer([:positive])}")

    systemctl_path = Path.join(tmp_dir, "systemctl")

    File.mkdir_p!(tmp_dir)
    File.write!(systemctl_path, script)
    File.chmod!(systemctl_path, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", "#{tmp_dir}:#{original_path}")

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
      File.rm_rf!(tmp_dir)
    end
  end
end
