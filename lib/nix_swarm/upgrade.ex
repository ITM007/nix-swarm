defmodule NixSwarm.Upgrade do
  @moduledoc false

  alias NixSwarm.Paths

  @default_timeout_ms 30 * 60 * 1_000

  def run(
        opts \\ [],
        deploy_fun \\ &NixSwarm.Deploy.run/1,
        command_fun \\ &run_command/3
      ) do
    source = Keyword.get(opts, :source, Paths.default_source()) |> Path.expand()
    timeout_ms = Keyword.get(opts, :command_timeout_ms, @default_timeout_ms)

    unless File.exists?(Path.join(source, "flake.nix")) do
      raise ArgumentError, "flake.nix does not exist under #{source}"
    end

    lock_path = Path.join(source, "flake.lock")
    previous_lock = File.read(lock_path)

    case command_fun.(
           "nix",
           ["flake", "update", "nix-swarm", "--flake", source],
           timeout_ms
         ) do
      {output, 0} ->
        try do
          deploy = deploy_fun.(Keyword.put(opts, :source, source))
          %{source: source, lock_output: String.trim(output), deploy: deploy}
        rescue
          deploy_error ->
            restore_lock!(lock_path, previous_lock)

            raise RuntimeError,
                  "upgrade deployment failed and flake.lock was restored: #{Exception.message(deploy_error)}"
        end

      {output, status} ->
        raise RuntimeError,
              "failed to update the nix-swarm flake input (#{status}): #{String.trim(output)}"
    end
  end

  defp restore_lock!(path, {:ok, contents}), do: File.write!(path, contents)

  defp restore_lock!(path, {:error, :enoent}) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "remove", path: path
    end
  end

  defp restore_lock!(_path, {:error, reason}),
    do: raise(RuntimeError, "could not preserve flake.lock before upgrade: #{inspect(reason)}")

  defp run_command(executable, args, timeout_ms) do
    task =
      Task.Supervisor.async_nolink(NixSwarm.TaskSupervisor, fn ->
        System.cmd(executable, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> raise RuntimeError, "#{executable} timed out after #{timeout_ms}ms"
    end
  rescue
    error in ErlangError ->
      raise RuntimeError, "could not execute #{executable}: #{Exception.message(error)}"
  end
end
