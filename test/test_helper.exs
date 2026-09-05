# The application and its test socket are process-global; lifecycle tests
# stop/restart it, so allowing cases to overlap races with other modules.
ExUnit.start(max_cases: 1)

System.cmd("epmd", ["-daemon"])

case :net_kernel.start([:"test-controller@127.0.0.1", :longnames]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
