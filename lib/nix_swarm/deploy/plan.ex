defmodule NixSwarm.Deploy.Plan do
  @moduledoc """
  The in-memory, reviewable deployment plan shown before mutation.
  """

  @spec build(map()) :: map()
  def build(deploy) when is_map(deploy) do
    %{
      source: deploy.source,
      fingerprint: fingerprint(deploy),
      current_health: :not_queried,
      bootstrap_targets: deploy.bootstrap_hosts,
      existing_targets: deploy.existing_hosts,
      maintenance_targets: maintenance_targets(deploy),
      blockers: [],
      warnings: [],
      credential_actions: credential_actions(deploy),
      closures: deploy.validation.targets,
      rollout_stages: Enum.map(deploy.batches, &Enum.map(&1, fn target -> target.host end)),
      rollout_policy: :sequential,
      health_policy: %{
        strategy: :sequential,
        timeout_sec: deploy.health_timeout_sec,
        stable_samples: deploy.health_stable_samples
      },
      rollback: :automatic_attempted_hosts
    }
  end

  @spec render(map()) :: String.t()
  def render(plan) when is_map(plan) do
    [
      "NixOS deployment plan (Nix-Swarm)",
      "  source: #{plan.source}",
      "  fingerprint: #{plan.fingerprint}",
      "  bootstrap targets: #{join(plan.bootstrap_targets)}",
      "  existing targets: #{join(plan.existing_targets)}",
      "  maintenance targets: #{join(plan.maintenance_targets)}",
      "  rollout policy: sequential, one host at a time",
      "  rollout stages: #{inspect(plan.rollout_stages)}",
      "  health: #{plan.health_policy.timeout_sec}s/#{plan.health_policy.stable_samples} stable samples",
      "  rollback: every attempted host on failure"
    ]
    |> Enum.join("\n")
  end

  def fingerprint(deploy) when is_map(deploy) do
    files =
      [
        Path.join(deploy.source, "flake.nix"),
        Path.join(deploy.source, "flake.lock"),
        deploy.cluster_file
      ]
      |> Enum.uniq()
      |> Enum.map(fn path ->
        {path, if(File.exists?(path), do: File.read!(path), else: "missing")}
      end)

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({files, deploy.deployment_manifest, deploy.validation.targets})
    )
    |> Base.encode16(case: :lower)
  end

  defp maintenance_targets(deploy) do
    deploy.deployment_manifest
    |> Map.get("nodes", %{})
    |> Enum.filter(fn {_node, metadata} ->
      Map.get(metadata, "availability", Map.get(metadata, :availability, "active")) ==
        "maintenance"
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp credential_actions(deploy) do
    Enum.map(deploy.bootstrap_hosts, &%{host: &1, action: :enroll_if_missing})
  end

  defp join([]), do: "none"
  defp join(values), do: Enum.join(values, ", ")
end
