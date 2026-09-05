scenario = System.get_env("NIX_SWARM_DOCKER_SCENARIO", "unspecified")

failure = System.get_env("NIX_SWARM_DOCKER_FAILURE", "")
label = if failure == "", do: "none", else: failure
IO.puts("verifying prepared-node scenario=#{scenario} failure_injection=#{label}")

{_output, status} =
  System.cmd(
    "nix",
    [
      "develop",
      "--command",
      "mix",
      "test",
      "test/integration/three_node_cluster_test.exs",
      "test/integration/stateful_heal_scenario_test.exs"
    ],
    into: IO.stream(:stdio, :line),
    stderr_to_stdout: true
  )

System.halt(status)
