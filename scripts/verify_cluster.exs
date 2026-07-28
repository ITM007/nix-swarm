scenario = System.get_env("NIX_SWARM_DOCKER_SCENARIO", "unspecified")

failure = System.get_env("NIX_SWARM_DOCKER_FAILURE", "")
IO.puts("verifying prepared-node scenario=#{scenario} failure_injection=#{if(failure == \"\", do: \"none\", else: failure)}")

{_output, status} = System.cmd("mix", ["test", "test/integration/three_node_cluster_test.exs"], into: IO.stream(:stdio, :line), stderr_to_stdout: true)
System.halt(status)
