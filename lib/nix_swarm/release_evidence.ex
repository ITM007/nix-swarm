defmodule NixSwarm.ReleaseEvidence do
  @moduledoc """
  Pure release-evidence catalog and secret-free text rendering.

  Evidence is transient text for review; it is not a desired-state or plan
  artifact and is never consumed by deployment code.
  """

  @type result :: {atom(), :passed | :failed | :unavailable, String.t()}

  @spec failure_matrix() :: [map()]
  def failure_matrix do
    [
      {:clean_bootstrap, "clean one-node initial bootstrap"},
      {:add_new_node, "add one new node to a healthy two-node cluster"},
      {:add_multiple_nodes, "add multiple new nodes"},
      {:missing_credential, "missing credential"},
      {:matching_credential, "matching credential"},
      {:mismatched_credential, "mismatched credential fails closed"},
      {:unreachable_target, "unreachable target"},
      {:wrong_architecture, "wrong architecture without builder"},
      {:low_disk, "low disk"},
      {:failed_bootstrap, "failed new-node activation"},
      {:existing_peer_failure, "existing peer update fails after bootstrap"},
      {:digest_drift, "mixed config digest blocks destructive reconciliation"},
      {:minor_upgrade, "successful minor rolling upgrade"},
      {:protocol_incompatible, "protocol-incompatible upgrade rejected before mutation"},
      {:canary_failure, "canary failure and rollback"},
      {:convergence_timeout, "final convergence timeout"},
      {:process_death, "deployment process dies while agents continue operating"},
      {:drain_before_removal, "removal only after draining and maintenance"},
      {:private_firewall, "private-interface firewall assertions"},
      {:disko_explicit_disk, "Disko profile evaluates with an explicit disk device"},
      {:hardened_template, "hardened template has no unsafe placeholders"},
      {:public_key_ssh, "public-key-only SSH policy rejects password login"},
      {:enrollment_readiness, "missing-only enrollment reaches service readiness"},
      {:closure_hygiene, "installed closure has no checkout, secrets, or toolchain"}
    ]
    |> Enum.map(fn {id, description} -> %{id: id, description: description} end)
  end

  @spec render_report(keyword()) :: String.t()
  def render_report(opts) when is_list(opts) do
    timestamp = Keyword.get(opts, :timestamp, "unknown")
    revision = Keyword.get(opts, :revision, "unknown")
    results = Keyword.get(opts, :results, [])

    lines =
      [
        "Nix-Swarm release evidence",
        "===========================",
        "timestamp: #{timestamp}",
        "revision: #{revision}",
        "",
        "results:"
      ] ++ Enum.map(results, &format_result/1)

    Enum.join(lines, "\n") <> "\n"
  end

  defp format_result({name, status, detail}) do
    "- #{name}: #{status} — #{redact(detail)}"
  end

  def redact(value) when is_binary(value) do
    value
    |> then(
      &Regex.replace(
        ~r/(?i)(cookie|secret|token|password|credential)([=: ]+)[^\s,;]+/,
        &1,
        "\\1\\2[REDACTED]"
      )
    )
    |> then(&Regex.replace(~r/[A-Fa-f0-9]{32,}/, &1, "[REDACTED]"))
  end

  def redact(value), do: inspect(value)
end
