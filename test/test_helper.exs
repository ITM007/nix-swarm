ExUnit.start()

System.cmd("epmd", ["-daemon"])

case :net_kernel.start([:"test-controller@127.0.0.1", :longnames]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
