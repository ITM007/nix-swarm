defmodule NixSwarm.ReleaseEvidenceScriptTest do
  use ExUnit.Case, async: true

  alias NixSwarm.ReleaseEvidence.Collector

  test "runs required gates in declared order and keeps later diagnostics after failure" do
    parent = self()

    runner = fn command ->
      send(parent, {:ran, command})
      if command == ["mix", "format", "--check-formatted"], do: {"bad", 1}, else: {"ok", 0}
    end

    result =
      Collector.collect(
        runner: runner,
        revision: fn -> "rev" end,
        clean?: fn -> true end,
        clock: {fn -> 0 end, fn -> 10 end},
        require_docker: false,
        gates: [{:format, ["mix", "format", "--check-formatted"]}, {:compile, ["mix", "compile"]}]
      )

    assert result.results |> Enum.map(& &1.name) == [:format, :compile]
    assert_received {:ran, ["mix", "format", "--check-formatted"]}
    assert_received {:ran, ["mix", "compile"]}
    assert result.status == :failed
  end

  test "required empty docker runtime is failed and output is always written" do
    test_pid = self()
    writer = fn path, report -> send(test_pid, {:written, path, report}) end

    result =
      Collector.collect(
        runner: fn _ -> {"", 0} end,
        revision: fn -> "rev" end,
        clean?: fn -> true end,
        writer: writer,
        require_docker: true,
        gates: [{:docker_standard_matrix, ["docker", "compose", "ps"]}],
        docker_services: ["node-a"]
      )

    assert result.status == :failed
    assert [%{status: :failed, detail: "empty_runtime"}] = result.results
    assert_received {:written, _, report}
    assert report =~ "empty_runtime"
  end

  test "dirty checkout is reported as a failed gate and commands stay argv lists" do
    result =
      Collector.collect(
        runner: fn command ->
          assert is_list(command)
          {"ok", 0}
        end,
        revision: fn -> "rev" end,
        clean?: fn -> false end,
        gates: [{:clean_checkout, ["git", "status", "--short"]}]
      )

    assert result.status == :failed
    assert [%{name: :clean_checkout, detail: "dirty_checkout"}] = result.results
  end
end