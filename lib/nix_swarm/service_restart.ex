defmodule NixSwarm.ServiceRestart do
  @moduledoc "Safely restarts the observed systemd units for one service."

  @doc """
  Restarts observed units in slot order and checks each one is running before
  continuing. The unit list is supplied by the operator after querying the
  cluster; this module never derives or persists desired state.

  An executor module can be supplied in the options for tests or alternate
  privileged transports.
  """
  def run(opts) when is_list(opts) do
    executor = Keyword.get(opts, :executor)
    command_fun = Keyword.get(opts, :command_fun)
    service = Keyword.fetch!(opts, :service)

    units =
      opts
      |> Keyword.fetch!(:units)
      |> Enum.sort_by(&Map.get(&1, :slot, 0))

    with {:ok, restarted} <- restart_units(units, executor, command_fun, []) do
      {:ok, %{service: service, units: Enum.reverse(restarted)}}
    end
  end

  defp restart_units([], _executor, _command_fun, restarted), do: {:ok, restarted}

  defp restart_units([%{unit: unit} = placement | rest], executor, command_fun, restarted) do
    with :ok <- restart_one(unit, placement, executor, command_fun),
         :ok <- ready_one(unit, placement, executor, command_fun) do
      restart_units(rest, executor, command_fun, [placement | restarted])
    else
      {:ok, status} ->
        {:error, "unit #{unit} is not ready after restart (status: #{status})"}

      {:error, reason} ->
        {:error, "failed to restart unit #{unit}: #{inspect(reason)}"}
    end
  end

  defp restart_one(unit, _placement, executor, _command_fun)
       when is_atom(executor) and not is_nil(executor),
       do: executor.restart_unit(unit)

  defp restart_one(unit, placement, nil, command_fun),
    do: remote_command(placement, ["restart", unit], command_fun)

  defp ready_one(unit, _placement, executor, _command_fun)
       when is_atom(executor) and not is_nil(executor) do
    if executor.unit_status(unit) == {:ok, :running}, do: :ok, else: {:error, :not_running}
  end

  defp ready_one(unit, placement, nil, command_fun),
    do: remote_command(placement, ["is-active", "--quiet", unit], command_fun)

  defp remote_command(%{deploy_host: host}, args, command_fun) when is_function(command_fun, 2) do
    case command_fun.("ssh", ssh_options() ++ ["--", host, "systemctl " <> Enum.join(args, " ")]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:remote_command_failed, status, output}}
    end
  end

  defp remote_command(_placement, _args, _command_fun), do: {:error, :missing_command_fun}

  defp ssh_options do
    [
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=10",
      "-o",
      "ServerAliveInterval=10",
      "-o",
      "ServerAliveCountMax=3",
      "-o",
      "StrictHostKeyChecking=yes",
      "-o",
      "ClearAllForwardings=yes",
      "-o",
      "ForwardAgent=no"
    ]
  end
end
