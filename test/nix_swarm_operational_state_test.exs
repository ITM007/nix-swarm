defmodule NixSwarmOperationalStateTest do
  use ExUnit.Case, async: false

  @app :nix_swarm

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "nix-swarm-opstate-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    previous_dir = System.get_env("NIX_SWARM_STATE_DIR")
    System.put_env("NIX_SWARM_STATE_DIR", root)

    on_exit(fn ->
      stop_app()

      if previous_dir,
        do: System.put_env("NIX_SWARM_STATE_DIR", previous_dir),
        else: System.delete_env("NIX_SWARM_STATE_DIR")

      # Leave the application running for later tests that assume it is up.
      _ = Application.ensure_all_started(@app)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp state_path(root) do
    node_dir =
      if Node.alive?() do
        NixSwarm.Executor.Fake.sanitize_node_name(Node.self())
      else
        "nonode"
      end

    Path.join([root, node_dir, "operational-state.dets"])
  end

  defp stop_app do
    case Application.stop(@app) do
      :ok -> :ok
      {:error, {:not_started, @app}} -> :ok
      other -> other
    end
  end

  test "a corrupt operational-state.dets is renamed aside and the agent starts empty", %{
    root: root
  } do
    stop_app()

    path = state_path(root)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "this is not a dets table, just garbage bytes to corrupt the store\n")

    assert {:ok, _apps} = Application.ensure_all_started(@app)

    assert NixSwarm.OperationalState.snapshot() == %{}

    assert [corrupt] = Path.wildcard(path <> ".corrupt-*")
    assert File.read!(corrupt) =~ "garbage bytes"
  end

  test "a healthy store keeps its snapshot across an agent restart", %{root: root} do
    stop_app()
    assert {:ok, _apps} = Application.ensure_all_started(@app)

    snapshot = NixSwarm.OperationalState.snapshot()
    assert snapshot == %{}
    assert NixSwarm.OperationalState.metadata().path == state_path(root)
  end

  test "a failed DETS write is returned and exposed as an unhealthy observation" do
    :sys.replace_state(NixSwarm.OperationalState, fn state ->
      %{state | persist_fun: fn _snapshot -> {:error, :disk_full} end}
    end)

    result =
      NixSwarm.OperationalState.record_reconcile(%{
        owned_units: ["failed-write-#{System.unique_integer([:positive])}.service"],
        assignments: [],
        results: []
      })

    assert {:error, :disk_full} = result
    assert %{status: :error, persistence_error: :disk_full} = NixSwarm.OperationalState.metadata()
  end
end
