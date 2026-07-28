defmodule NixSwarm.Deploy.Rollout do
  @moduledoc """
  Plans the two-stage deployment of new and existing Nix-Swarm nodes.

  Bootstrap targets are activated first. Existing targets are then ordered by
  the Nix-defined canary and bounded-unavailable policy. This module is pure:
  it never runs SSH, Nix, or systemd commands.
  """

  alias NixSwarm.Deploy.Target

  @new_classifications [:new_nixos_host, :installed_inactive]
  @existing_classifications [:existing_in_sync, :existing_outdated, :installed_unqueryable]

  @spec plan([map()], keyword()) :: %{bootstrap: [map()], existing: [map()], stages: [[map()]]}
  def plan(targets, opts \\ []) when is_list(targets) and is_list(opts) do
    max_unavailable = positive_integer!(Keyword.get(opts, :max_unavailable, 1))
    canary_hosts = MapSet.new(Keyword.get(opts, :canary_hosts, []) |> Enum.map(&to_string/1))
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

    ordered_existing = order_existing(existing, canary_hosts)
    stages = Enum.map(bootstrap, &[&1]) ++ batches(ordered_existing, max_unavailable)

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

  defp order_existing(targets, canary_hosts) do
    Enum.sort_by(targets, fn target ->
      {if(MapSet.member?(canary_hosts, target.host), do: 0, else: 1), target.host}
    end)
  end

  defp batches([], _width), do: []
  defp batches(targets, width), do: Enum.chunk_every(targets, width)

  defp positive_integer!(value) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value),
    do:
      raise(
        ArgumentError,
        "rollout max_unavailable must be a positive integer, got #{inspect(value)}"
      )
end
