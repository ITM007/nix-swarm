defmodule NixSwarmExecutorFakeTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Executor.Fake

  setup do
    root = Path.join(System.tmp_dir!(), "nix-swarm-fake-#{System.unique_integer([:positive])}")
    config = %{root: root, node_name: :fake@node}
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, config: config}
  end

  test "tracks complete unit lifecycle, logs, status batches, and metrics", %{config: config} do
    assert {:ok, :stopped} = Fake.unit_status("demo.service", config)
    assert :ok = Fake.start_unit("demo.service", config)
    assert {:ok, :running} = Fake.unit_status("demo.service", config)
    assert %{"demo.service" => {:ok, :running}} = Fake.batch_unit_status(["demo.service"], config)

    assert :ok = Fake.restart_unit("demo.service", config)
    assert {:ok, logs} = Fake.unit_logs("demo.service", 10, config)
    assert logs =~ "start"
    assert logs =~ "restart"

    assert %{cpu: %{usage_ns: usage}, memory: %{used: memory}} =
             Fake.unit_metrics("demo.service", config)

    assert usage > 0
    assert memory > 0

    assert :ok = Fake.stop_unit("demo.service", config)
    assert {:ok, :stopped} = Fake.unit_status("demo.service", config)
    assert %{cpu: %{usage_ns: 0}, memory: %{used: 0}} = Fake.unit_metrics("demo.service", config)
  end

  test "isolates state by sanitized node name" do
    assert Fake.sanitize_node_name(:fake@node) == "fake_node"
  end
end
