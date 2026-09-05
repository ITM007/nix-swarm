defmodule NixSwarm.Deploy.Heal do
  @moduledoc """
  Restore-verified state recovery for a single stateful service.

  `run/1` restores the service's declared state directories onto one host
  from the latest backup snapshot and only then starts the unit:

    1. prepare a fresh `<dir>.restore-tmp` staging directory on the host;
    2. run the service's restore wrapper (`nix-swarm-restore-<service>`,
       installed on every node by the NixOS module) into the staging dir;
    3. verify the staging dir is non-empty (restore succeeded);
    4. atomically move the staging dir into place;
    5. start the unit and confirm it is running.

  Every failure removes the staging directory and leaves any existing target
  untouched (fail closed). This module never derives desired state; the unit,
  directories, and restore strategy are supplied by the operator from cluster
  observations.
  """

  alias NixSwarm.Executor

  @default_restore_bin "/run/current-system/sw/bin"

  def run(opts) when is_list(opts) do
    service = Keyword.fetch!(opts, :service)
    unit = Keyword.fetch!(opts, :unit)
    dirs = Keyword.fetch!(opts, :dirs)
    host = Keyword.fetch!(opts, :host)
    command_fun = Keyword.get(opts, :command_fun)

    with :ok <- Executor.validate_unit_name(unit),
         :ok <- validate_dirs(dirs),
         {:ok, restore_bin} <- resolve_restore_bin(opts, service) do
      executor = Keyword.get(opts, :executor)

      case restore_dirs(dirs, restore_bin, host, command_fun) do
        {:ok, restored} ->
          case start_unit(unit, executor, host, command_fun) do
            :ok ->
              {:ok, %{service: service, unit: unit, host: host, restored: restored}}

            {:error, reason} ->
              {:error, {:start_failed, unit, reason}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_restore_bin(opts, service) do
    case Keyword.get(opts, :restore_command) do
      nil -> {:ok, "#{@default_restore_bin}/nix-swarm-restore-#{service}"}
      command -> {:ok, to_string(command)}
    end
  end

  defp validate_dirs(dirs) when is_list(dirs) and dirs != [] do
    if Enum.all?(dirs, &(is_binary(&1) and String.starts_with?(&1, "/"))) do
      :ok
    else
      {:error, {:invalid_state_dirs, dirs}}
    end
  end

  defp validate_dirs(dirs), do: {:error, {:invalid_state_dirs, dirs}}

  defp restore_dirs(dirs, restore_bin, host, command_fun) do
    Enum.reduce_while(dirs, {:ok, []}, fn dir, {:ok, restored} ->
      staging = staging_path(dir)
      parent = Path.dirname(dir)

      with {:ok, _} <- remote(command_fun, host, prepare_staging(parent, dir, staging)),
           {:ok, _} <- remote(command_fun, host, restore_command(restore_bin, staging)),
           {:ok, _} <- remote(command_fun, host, verify_staging(dir, staging)),
           {:ok, _} <- remote(command_fun, host, move_into_place(dir, staging)) do
        {:cont, {:ok, [dir | restored]}}
      else
        {:error, reason} ->
          cleanup(command_fun, host, staging)
          {:halt, {:error, {:restore_failed, dir, reason}}}
      end
    end)
    |> case do
      {:ok, restored} -> {:ok, Enum.reverse(restored)}
      {:error, _} = error -> error
    end
  end

  defp prepare_staging(parent, dir, staging) do
    shell(
      "mkdir -p #{shq(parent)} && test ! -e #{shq(dir)} && rm -rf #{shq(staging)} && mkdir -p #{shq(staging)}"
    )
  end

  defp restore_command(restore_bin, staging) do
    shell("#{shq(restore_bin)} #{shq(staging)}")
  end

  defp verify_staging(dir, staging) do
    shell("test -n \"$(ls -A #{shq(staging)})\" && test -d #{shq(staging)}")
  end

  defp move_into_place(dir, staging) do
    shell("mv #{shq(staging)} #{shq(dir)}")
  end

  defp cleanup(command_fun, host, staging) do
    remote(command_fun, host, shell("rm -rf #{shq(staging)}"))
  end

  defp start_unit(unit, executor, _host, _command_fun)
       when is_atom(executor) and not is_nil(executor) do
    case executor.start_unit(unit) do
      :ok ->
        if executor.unit_status(unit) == {:ok, :running},
          do: :ok,
          else: {:error, :not_running}

      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_unit(unit, nil, host, command_fun) when is_function(command_fun, 2) do
    with {:ok, _} <- remote(command_fun, host, shell("systemctl start #{shq(unit)}")),
         {:ok, _} <- remote(command_fun, host, shell("systemctl is-active --quiet #{shq(unit)}")) do
      :ok
    end
  end

  defp start_unit(_unit, nil, _host, _command_fun), do: {:error, :missing_command_fun}

  defp remote(command_fun, host, command) when is_function(command_fun, 2) do
    case command_fun.("ssh", ssh_options() ++ ["--", host, command]) do
      {_output, 0} -> {:ok, :done}
      {output, status} -> {:error, {:remote_command_failed, status, output}}
    end
  end

  defp remote(_command_fun, _host, _command), do: {:error, :missing_command_fun}

  defp shell(command), do: "sh -c " <> shq(command)

  # Single-quote a string for a remote sh -c invocation.
  defp shq(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end

  defp staging_path(dir), do: dir <> ".restore-tmp"

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
