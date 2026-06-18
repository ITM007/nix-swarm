defmodule NixSwarmExecutorTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Executor

  describe "validate_unit_name/1" do
    test "accepts typical systemd unit names" do
      for name <- [
            "gitea.service",
            "nix-swarm.service",
            "nix-swarm-agent.service",
            "redis@1.service",
            "user_app.service",
            "my.app.target",
            "ssh.socket"
          ] do
        assert :ok == Executor.validate_unit_name(name), "expected #{inspect(name)} to be valid"
      end
    end

    test "rejects argument-injection and path-traversal attempts" do
      for name <- [
            "-rf",
            "--root=/etc/passwd",
            "../../etc/passwd",
            "..",
            ".hidden",
            "foo bar.service",
            "foo;rm -rf /",
            "foo|cat /etc/shadow",
            "foo`whoami`",
            "foo$(id).service",
            "",
            String.duplicate("a", 300)
          ] do
        assert {:error, :invalid_unit_name} ==
                 Executor.validate_unit_name(name),
               "expected #{inspect(name)} to be rejected"
      end
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_unit_name} == Executor.validate_unit_name(nil)
      assert {:error, :invalid_unit_name} == Executor.validate_unit_name(:atom)
      assert {:error, :invalid_unit_name} == Executor.validate_unit_name(123)
    end
  end

  describe "executor dispatch with bad unit names" do
    test "start/stop/restart return {:error, :invalid_unit_name}" do
      assert {:error, :invalid_unit_name} = Executor.start_unit("../evil")
      assert {:error, :invalid_unit_name} = Executor.stop_unit("--root=/etc")
      assert {:error, :invalid_unit_name} = Executor.restart_unit("foo;rm")
    end

    test "unit_status returns :unknown for invalid names" do
      assert {:ok, :unknown} = Executor.unit_status("../evil")
    end

    test "unit_logs returns {:error, :invalid_unit_name}" do
      assert {:error, :invalid_unit_name} = Executor.unit_logs("../evil", 10)
    end

    test "unit_metrics returns zeroed metrics" do
      metrics = Executor.unit_metrics("../evil")
      assert metrics.cpu.usage_ns == 0
      assert metrics.memory.used == 0
      assert metrics.disk.used == 0
      assert metrics.network.counter == 0
    end
  end
end
