defmodule NixSwarm.Deploy.Rollout do
  @moduledoc """
  Plans the sequential deployment of new and existing Nix-Swarm nodes.

  Bootstrap targets are activated first. Every target is then deployed one at
  a time in stable host order. This module is pure:
  it never runs SSH, Nix, or systemd commands.
  """

  alias NixSwarm.Deploy.Target

  @new_classifications [:new_nixos_host, :installed_inactive]
  @existing_classifications [:existing_in_sync, :existing_outdated, :installed_unqueryable]
  @rollout_width 1

  @spec plan([map()], keyword()) :: %{bootstrap: [map()], existing: [map()], stages: [[map()]]}
  def plan(targets, opts \\ []) when is_list(targets) and is_list(opts) do
    classifications = Keyword.get(opts, :classifications, %{})

    normalized = Enum.map(targets, &normalize_target!(&1, classifications))

    {bootstrap, existing} =
      Enum.split_with(normalized, &(&1.classification in @new_classifications))

    invalid =
      Enum.reject(
        normalized,
        &(&1.classification in (@new_classifications ++ @existing_classifications))
      )

    if invalid != [] do
      details = Enum.map_join(invalid, ", ", &"#{&1.host}=#{&1.classification}")
      raise ArgumentError, "rollout cannot mutate blocked target(s): #{details}"
    end

    ordered_existing = Enum.sort_by(existing, & &1.host)
    stages = Enum.map(bootstrap, &[&1]) ++ batches(ordered_existing, @rollout_width)

    %{bootstrap: bootstrap, existing: ordered_existing, stages: stages}
  end

  def attempted_hosts(stages, stage_index) when is_list(stages) and is_integer(stage_index) do
    stages
    |> Enum.take(max(stage_index, 0))
    |> List.flatten()
    |> Enum.map(& &1.host)
  end

  def unattempted_hosts(stages, stage_index) when is_list(stages) and is_integer(stage_index) do
    stages
    |> Enum.drop(max(stage_index, 0))
    |> List.flatten()
    |> Enum.map(& &1.host)
  end

  defp normalize_target!(%Target{} = target, classifications) do
    %{
      target
      | classification:
          Map.get(classifications, target.host, target.classification || :existing_outdated)
    }
  end

  defp normalize_target!(target, classifications) when is_map(target) do
    host = to_string(Map.fetch!(target, :host))

    target
    |> Map.put(:host, host)
    |> Map.put(:configuration, to_string(Map.fetch!(target, :configuration)))
    |> Map.put(
      :classification,
      Map.get(classifications, host, Map.get(target, :classification, :existing_outdated))
    )
  end

  defp batches([], _width), do: []
  defp batches(targets, width), do: Enum.chunk_every(targets, width)
end
