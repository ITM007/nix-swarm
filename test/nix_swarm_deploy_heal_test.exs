defmodule NixSwarmDeployHealTest do
  use ExUnit.Case, async: false

  defmodule RecordingExecutor do
    def start_unit(unit) do
      send(Process.get(:test_pid), {:start_unit, unit})
      :ok
    end

    def unit_status(_unit) do
      send(Process.get(:test_pid), {:status_checked, true})
      {:ok, :running}
    end
  end

  defmodule StartFailingExecutor do
    def start_unit(unit) do
      send(Process.get(:test_pid), {:start_unit, unit})
      :ok
    end

    def unit_status(_unit), do: {:ok, :stopped}
  end

  # Runs the remote command locally: ssh-style args end with the "sh -c ..."
  # payload, which is executed through a local shell.
  defp local_command_fun do
    fn _executable, args ->
      payload = List.last(args)
      System.cmd("sh", ["-c", payload], stderr_to_stdout: true)
    end
  end

  defp write_script!(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "nix-swarm-heal-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)
    Process.put(:test_pid, self())

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "restores into staging, verifies, moves into place, then starts the unit", %{root: root} do
    backup = Path.join(root, "backup")
    dir = Path.join(root, "state")
    File.mkdir_p!(backup)
    File.write!(Path.join(backup, "marker.txt"), "recovered\n")

    script =
      write_script!(Path.join(root, "restore.sh"), """
      #!/bin/sh
      cp -R '#{backup}/.' "$1"
      """)

    assert {:ok, %{service: "paperless", unit: "paperless.service", restored: [^dir]}} =
             NixSwarm.Deploy.Heal.run(
               service: "paperless",
               unit: "paperless.service",
               dirs: [dir],
               host: "root@node-b",
               restore_command: script,
               executor: RecordingExecutor,
               command_fun: local_command_fun()
             )

    assert File.read!(Path.join(dir, "marker.txt")) == "recovered\n"
    refute File.exists?(dir <> ".restore-tmp")
    assert_received {:start_unit, "paperless.service"}
    assert_received {:status_checked, true}
  end

  test "restores every declared directory before starting", %{root: root} do
    backup = Path.join(root, "backup")
    dir_a = Path.join(root, "data")
    dir_b = Path.join(root, "uploads")
    File.mkdir_p!(Path.join(backup, "a"))
    File.mkdir_p!(Path.join(backup, "b"))
    File.write!(Path.join([backup, "a", "x"]), "x")
    File.write!(Path.join([backup, "b", "y"]), "y")

    script =
      write_script!(Path.join(root, "restore.sh"), """
      #!/bin/sh
      cp -R '#{backup}/a/.' "$1"
      cp -R '#{backup}/b/.' "$1"
      """)

    assert {:ok, %{restored: [^dir_a, ^dir_b]}} =
             NixSwarm.Deploy.Heal.run(
               service: "paperless",
               unit: "paperless.service",
               dirs: [dir_a, dir_b],
               host: "root@node-b",
               restore_command: script,
               executor: RecordingExecutor,
               command_fun: local_command_fun()
             )

    assert File.read!(Path.join(dir_a, "x")) == "x"
    assert File.read!(Path.join(dir_a, "y")) == "y"
    assert File.read!(Path.join(dir_b, "x")) == "x"
    assert File.read!(Path.join(dir_b, "y")) == "y"
    assert_received {:start_unit, "paperless.service"}
  end

  test "a failed restore removes staging, leaves no target, and never starts the unit", %{
    root: root
  } do
    dir = Path.join(root, "state")

    script =
      write_script!(Path.join(root, "restore.sh"), """
      #!/bin/sh
      echo "repository unreachable" >&2
      exit 1
      """)

    assert {:error, {:restore_failed, ^dir, {:remote_command_failed, 1, _output}}} =
             NixSwarm.Deploy.Heal.run(
               service: "paperless",
               unit: "paperless.service",
               dirs: [dir],
               host: "root@node-b",
               restore_command: script,
               executor: RecordingExecutor,
               command_fun: local_command_fun()
             )

    refute File.exists?(dir)
    refute File.exists?(dir <> ".restore-tmp")
    refute_received {:start_unit, _unit}
  end

  test "an empty restore is treated as failure: cleaned up, no unit start", %{root: root} do
    dir = Path.join(root, "state")

    script =
      write_script!(Path.join(root, "restore.sh"), """
      #!/bin/sh
      exit 0
      """)

    assert {:error, {:restore_failed, ^dir, {:remote_command_failed, 1, _output}}} =
             NixSwarm.Deploy.Heal.run(
               service: "paperless",
               unit: "paperless.service",
               dirs: [dir],
               host: "root@node-b",
               restore_command: script,
               executor: RecordingExecutor,
               command_fun: local_command_fun()
             )

    refute File.exists?(dir)
    refute File.exists?(dir <> ".restore-tmp")
    refute_received {:start_unit, _unit}
  end

  test "a unit that fails to come up reports start failure after the restore landed", %{
    root: root
  } do
    backup = Path.join(root, "backup")
    dir = Path.join(root, "state")
    File.mkdir_p!(backup)
    File.write!(Path.join(backup, "marker.txt"), "recovered\n")

    script =
      write_script!(Path.join(root, "restore.sh"), """
      #!/bin/sh
      cp -R '#{backup}/.' "$1"
      """)

    assert {:error, {:start_failed, "paperless.service", :not_running}} =
             NixSwarm.Deploy.Heal.run(
               service: "paperless",
               unit: "paperless.service",
               dirs: [dir],
               host: "root@node-b",
               restore_command: script,
               executor: StartFailingExecutor,
               command_fun: local_command_fun()
             )

    # state was restored and left in place even though the start failed
    assert File.read!(Path.join(dir, "marker.txt")) == "recovered\n"
    assert_received {:start_unit, "paperless.service"}
  end

  test "an existing target directory fails closed before any restore runs", %{root: root} do
    dir = Path.join(root, "state")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "precious"), "keep")

    script =
      write_script!(Path.join(root, "restore.sh"), """
      #!/bin/sh
      exit 1
      """)

    assert {:error, {:restore_failed, ^dir, {:remote_command_failed, 1, _}}} =
             NixSwarm.Deploy.Heal.run(
               service: "paperless",
               unit: "paperless.service",
               dirs: [dir],
               host: "root@node-b",
               restore_command: script,
               executor: RecordingExecutor,
               command_fun: local_command_fun()
             )

    assert File.read!(Path.join(dir, "precious")) == "keep"
    refute_received {:start_unit, _unit}
  end

  test "rejects unsafe unit names before any remote command runs" do
    parent = self()

    command_fun = fn _executable, _args ->
      send(parent, {:remote_command, "unexpected"})
      {"", 0}
    end

    assert {:error, :invalid_unit_name} =
             NixSwarm.Deploy.Heal.run(
               service: "demo",
               unit: "foo;rm",
               dirs: ["/var/lib/demo"],
               host: "root@node-a",
               command_fun: command_fun
             )

    refute_received {:remote_command, _}
  end

  test "rejects non-absolute or empty state dirs" do
    for dirs <- [[], ["relative/path"]] do
      assert {:error, {:invalid_state_dirs, ^dirs}} =
               NixSwarm.Deploy.Heal.run(
                 service: "demo",
                 unit: "demo.service",
                 dirs: dirs,
                 host: "root@node-a",
                 command_fun: fn _, _ -> {"", 0} end
               )
    end
  end

  test "without an executor or command fun the heal fails closed" do
    assert {:error, {:restore_failed, _dir, :missing_command_fun}} =
             NixSwarm.Deploy.Heal.run(
               service: "demo",
               unit: "demo.service",
               dirs: ["/var/lib/demo"],
               host: "root@node-a"
             )
  end
end
