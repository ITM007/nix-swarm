{_output, status} = System.cmd("mix", ["test", "test/integration/three_node_cluster_test.exs"], into: IO.stream(:stdio, :line), stderr_to_stdout: true)
System.halt(status)
