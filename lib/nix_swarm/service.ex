defmodule NixSwarm.Service do
  @moduledoc false

  alias NixSwarm.NodeName

  @state_top_level_keys [
    :dirs,
    :backup,
    :restore,
    :auto_heal,
    :autoHeal,
    :heal_grace_sec,
    :healGraceSec,
    :on_placement,
    :onPlacement
  ]

  def normalize(raw) do
    name = NixSwarm.fetch_value(raw, :name) |> to_string()
    replicas = NixSwarm.fetch_value(raw, :replicas, 1) |> normalize_integer(1)
    autoscaling = normalize_autoscaling(NixSwarm.fetch_value(raw, :autoscaling, %{}), replicas)
    replica_capacity = if autoscaling.enabled, do: autoscaling.max_replicas, else: replicas
    unit_template = normalize_unit_template(preferred_template(raw), replica_capacity)
    state = normalize_state(NixSwarm.fetch_value(raw, :state), name)

    %{
      name: name,
      replicas: replicas,
      unit_template: unit_template,
      allowed_nodes:
        NixSwarm.fetch_value(raw, :allowed_nodes, NixSwarm.fetch_value(raw, :allowedNodes, []))
        |> normalize_nodes(),
      autoscaling: autoscaling,
      state: state
    }
  end

  def stateful?(%{state: nil}), do: false
  def stateful?(%{state: _}), do: true

  @doc """
  Whether a stateful service must restore state from a snapshot before it may
  start (as opposed to `restore: "none"`, which only governs backups and
  fencing, never starts on a node without its state).
  """
  def awaiting_restore?(%{state: %{restore: restore}})
      when restore in ["borg-latest", "litestream"],
      do: true

  def awaiting_restore?(_service), do: false

  def state_dirs(%{state: %{dirs: dirs}}) when is_list(dirs), do: dirs
  def state_dirs(_service), do: []

  def default_unit_template(replicas) when replicas <= 1, do: "%{service}.service"
  def default_unit_template(_replicas), do: "%{service}@%{slot}.service"

  def slots(service), do: slots(service, service.replicas)
  def slots(_service, replicas) when replicas <= 0, do: []
  def slots(_service, replicas), do: Enum.to_list(0..(replicas - 1))

  def capacity_replicas(%{autoscaling: %{enabled: true, max_replicas: replicas}}), do: replicas
  def capacity_replicas(service), do: service.replicas

  def unit_name(service, slot) do
    service.unit_template
    |> String.replace("@.service", "@#{slot}.service")
    |> String.replace("%{slot}", Integer.to_string(slot))
    |> String.replace("%{service}", service.name)
  end

  defp normalize_autoscaling(raw, replicas) do
    enabled =
      NixSwarm.fetch_value(raw, :enable, NixSwarm.fetch_value(raw, :enabled, false)) == true

    %{
      enabled: enabled,
      min_replicas:
        raw
        |> NixSwarm.fetch_value(
          :min_replicas,
          NixSwarm.fetch_value(raw, :minReplicas, replicas)
        )
        |> normalize_integer(replicas),
      max_replicas:
        raw
        |> NixSwarm.fetch_value(
          :max_replicas,
          NixSwarm.fetch_value(raw, :maxReplicas, replicas)
        )
        |> normalize_integer(replicas),
      cpu_target_percent:
        raw
        |> NixSwarm.fetch_value(
          :cpu_target_percent,
          NixSwarm.fetch_value(raw, :cpuTargetPercent, 65)
        )
        |> normalize_integer(65),
      memory_target_percent:
        raw
        |> NixSwarm.fetch_value(
          :memory_target_percent,
          NixSwarm.fetch_value(raw, :memoryTargetPercent, 80)
        )
        |> normalize_integer(80)
    }
  end

  defp preferred_template(raw) do
    case normalize_optional(NixSwarm.fetch_value(raw, :unit_template)) do
      nil -> normalize_optional(NixSwarm.fetch_value(raw, :unit))
      value -> value
    end
  end

  defp normalize_unit_template(nil, replicas), do: default_unit_template(replicas)
  defp normalize_unit_template(template, _replicas), do: to_string(template)

  defp normalize_nodes(values) do
    values
    |> List.wrap()
    |> Enum.map(&normalize_node_name/1)
    |> Enum.uniq()
  end

  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp normalize_integer(_value, default), do: default

  defp normalize_optional(value) when value in [nil, :undefined, "undefined"], do: nil
  defp normalize_optional(value), do: value

  defp normalize_node_name(name) when is_atom(name), do: name
  defp normalize_node_name(name), do: NodeName.to_node!(name, label: "allowed node name")

  defp normalize_state(nil, _service_name), do: nil

  defp normalize_state(raw, service_name) when is_map(raw) do
    reject_unknown_state_keys!(raw, service_name)
    dirs = normalize_state_dirs!(NixSwarm.fetch_value(raw, :dirs), service_name)
    backup = normalize_backup(NixSwarm.fetch_value(raw, :backup), service_name)
    restore = normalize_restore(raw, backup, service_name)

    auto_heal =
      raw
      |> NixSwarm.fetch_value(:auto_heal, NixSwarm.fetch_value(raw, :autoHeal, false))
      |> Kernel.==(true)

    heal_grace_sec =
      raw
      |> NixSwarm.fetch_value(
        :heal_grace_sec,
        NixSwarm.fetch_value(raw, :healGraceSec, 600)
      )
      |> normalize_positive_integer(600)

    %{
      dirs: dirs,
      backup: backup,
      restore: restore,
      auto_heal: auto_heal,
      heal_grace_sec: heal_grace_sec
    }
  end

  defp normalize_state(raw, service_name), do: raise_state!(service_name, "state", raw)

  defp normalize_state_dirs!(dirs, service_name) when is_list(dirs) do
    normalized = Enum.map(dirs, &to_string/1)

    if normalized == [] do
      raise ArgumentError, "service #{service_name} state.dirs must not be empty"
    end

    if Enum.any?(normalized, &(not String.starts_with?(&1, "/"))) do
      raise ArgumentError,
            "service #{service_name} state.dirs must be absolute paths, got #{inspect(normalized)}"
    end

    normalized
  end

  defp normalize_state_dirs!(dirs, service_name) do
    raise ArgumentError,
          "service #{service_name} state.dirs must be a list of absolute paths, got #{inspect(dirs)}"
  end

  defp normalize_backup(backup, service_name) when backup in [nil, :undefined, "undefined"],
    do: nil

  defp normalize_backup(raw, service_name) when is_map(raw) do
    target =
      raw
      |> NixSwarm.fetch_value(:target)
      |> normalize_optional_string()

    if is_nil(target) do
      raise ArgumentError,
            "service #{service_name} state.backup.target is required (borg repository URI)"
    end

    schedule =
      raw
      |> NixSwarm.fetch_value(:schedule, "hourly")
      |> to_string()

    %{schedule: schedule, target: target}
  end

  defp normalize_backup(backup, service_name),
    do: raise_state!(service_name, "state.backup", backup)

  defp normalize_restore(raw, backup, service_name) do
    restore =
      raw
      |> fetch_nested_restore()
      |> normalize_optional_string()

    restore =
      cond do
        not is_nil(restore) ->
          restore

        not is_nil(backup) ->
          "borg-latest"

        true ->
          "none"
      end

    if restore not in ["borg-latest", "litestream", "none"] do
      raise ArgumentError,
            "service #{service_name} state.restore must be one of \"borg-latest\", \"litestream\", or \"none\", got #{inspect(restore)}"
    end

    if restore != "none" and is_nil(backup) do
      raise ArgumentError,
            "service #{service_name} state.restore #{inspect(restore)} requires a state.backup block"
    end

    restore
  end

  defp fetch_nested_restore(raw) do
    case NixSwarm.fetch_value(raw, :restore) do
      nil ->
        on_placement =
          NixSwarm.fetch_value(raw, :on_placement, NixSwarm.fetch_value(raw, :onPlacement))

        case on_placement do
          %{} = nested -> NixSwarm.fetch_value(nested, :restore)
          _ -> nil
        end

      restore ->
        restore
    end
  end

  defp reject_unknown_state_keys!(raw, service_name) do
    allowed = Enum.map(@state_top_level_keys, &Atom.to_string/1)

    raw
    |> Enum.map(fn {key, _value} -> normalize_optional_string(key) end)
    |> Enum.reject(&(&1 in allowed))
    |> case do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "service #{service_name} state has unsupported key(s): #{Enum.join(unknown, ", ")}"
    end
  end

  defp normalize_positive_integer(value, default) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp raise_state!(service_name, key, value) do
    raise ArgumentError,
          "service #{service_name} #{key} must be a map, got #{inspect(value)}"
  end
end
