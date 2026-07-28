defmodule NixSwarm.Deploy.Preflight do
  @moduledoc """
  Performs bounded, non-secret target probes and classifies deployment targets.

  The default adapter is intentionally conservative. Tests and operators may
  inject an adapter returning normalized probe values without ever returning a
  credential's contents.
  """

  alias NixSwarm.Deploy.Target

  @default_timeout_ms 15_000
  @required_probe_keys [
    :ssh,
    :nixos,
    :privilege,
    :architecture,
    :disk,
    :credential,
    :service,
    :query
  ]

  @spec run(Target.t() | map(), keyword()) :: Target.t()
  def run(target, opts \\ []) when is_map(target) and is_list(opts) do
    target = normalize_target!(target)
    probe_fun = Keyword.get(opts, :probe_fun, &default_probe/2)

    probes =
      probe_fun.(target, Keyword.get(opts, :timeout_ms, @default_timeout_ms))
      |> normalize_probes()

    classify(target, probes)
  end

  @spec classify(Target.t() | map(), map()) :: Target.t()
  def classify(target, probes) when is_map(target) and is_map(probes) do
    target = normalize_target!(target)
    blockers = blockers(probes)
    warnings = warnings(probes)
    classification = classification(probes, blockers)

    %{
      target
      | probes: redact_probes(probes),
        classification: classification,
        blockers: blockers,
        warnings: warnings
    }
  end

  def ready?(%Target{classification: classification, blockers: []})
      when classification in [
             :new_nixos_host,
             :installed_inactive,
             :existing_in_sync,
             :existing_outdated
           ],
      do: true

  def ready?(_target), do: false

  defp normalize_target!(%Target{} = target), do: target

  defp normalize_target!(target) do
    host = Map.fetch!(target, :host)
    configuration = Map.fetch!(target, :configuration)

    %Target{
      host: to_string(host),
      configuration: to_string(configuration),
      node: target[:node] && to_string(target[:node]),
      system: target[:system] && to_string(target[:system])
    }
  end

  defp normalize_probes(probes) do
    Map.new(probes, fn {key, value} -> {key, normalize_probe(value)} end)
  end

  defp normalize_probe(value) when value in [true, false], do: %{ok: value}
  defp normalize_probe(:ok), do: %{ok: true}
  defp normalize_probe(:missing), do: %{ok: true, state: :missing}
  defp normalize_probe(:present), do: %{ok: true, state: :present}
  defp normalize_probe({:ok, state}) when is_atom(state), do: %{ok: true, state: state}
  defp normalize_probe({:error, reason}), do: %{ok: false, error: inspect(reason)}
  defp normalize_probe(%{} = value), do: value
  defp normalize_probe(value), do: %{ok: false, state: value}

  defp blockers(probes) do
    []
    |> add_blocker(probes, :ssh, "SSH authentication or host-key verification failed")
    |> add_blocker(probes, :nixos, "target is not a reachable NixOS system")
    |> add_blocker(
      probes,
      :privilege,
      "deployment privilege is not noninteractive root or passwordless sudo"
    )
    |> add_blocker(
      probes,
      :architecture,
      "target architecture is incompatible with the available build"
    )
    |> add_blocker(probes, :disk, "target does not have enough free disk space")
    |> add_blocker(probes, :credential, "shared credential is mismatched or inaccessible", [
      :mismatched,
      :inaccessible
    ])
    |> add_blocker(probes, :query, "installed target query API is incompatible", [:incompatible])
  end

  defp add_blocker(acc, probes, key, message, states \\ []) do
    probe = Map.get(probes, key, %{})

    if probe[:ok] == false or probe[:state] in states do
      [message | acc]
    else
      acc
    end
  end

  defp warnings(probes) do
    case Map.get(probes, :credential, %{})[:state] do
      :missing -> ["shared credential is missing and must be enrolled before activation"]
      _ -> []
    end
  end

  defp classification(probes, []) do
    service = Map.get(probes, :service, %{})
    query = Map.get(probes, :query, %{})
    credential = Map.get(probes, :credential, %{})

    cond do
      service[:state] == :missing and query[:state] in [nil, :missing] -> :new_nixos_host
      service[:state] == :inactive -> :installed_inactive
      query[:state] == :unqueryable -> :installed_unqueryable
      query[:state] == :draining -> :draining
      query[:state] == :maintenance -> :maintenance
      credential[:state] == :missing -> :installed_inactive
      query[:state] == :outdated -> :existing_outdated
      true -> :existing_in_sync
    end
  end

  defp classification(_probes, _blockers), do: :incompatible

  defp redact_probes(probes) do
    Map.new(probes, fn {key, value} ->
      {key, Map.drop(value, [:cookie, :contents, :secret, :value])}
    end)
  end

  defp default_probe(_target, _timeout),
    do: Map.new(@required_probe_keys, &{&1, %{ok: false, error: "probe adapter not configured"}})
end
