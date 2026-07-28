defmodule NixSwarm.ReleaseEvidence do
  @moduledoc "Release evidence catalog, validation, and bounded secret-free rendering."

  @type status :: :passed | :failed | :unavailable | :skipped
  @max_detail 4_000

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

  @spec aggregate_status([map()]) :: :passed | :failed | :incomplete
  def aggregate_status(results) do
    cond do
      Enum.any?(results, &(&1.status == :failed)) -> :failed
      Enum.any?(results, &(&1.status in [:unavailable, :skipped])) -> :incomplete
      true -> :passed
    end
  end

  def release_success?(results),
    do: aggregate_status(results) == :passed and Enum.all?(results, &(&1.status == :passed))

  def validate_runtime(_name, [], expected_services: services) when services != [],
    do: {:failed, "empty_runtime"}

  def validate_runtime(_name, output, expected_services: services) when is_binary(output) do
    if Enum.all?(services, fn service -> String.contains?(output, service) end),
      do: :passed,
      else: {:failed, "empty_runtime"}
  end

  def validate_runtime(_name, services, expected_services: expected) when is_list(services) do
    if Enum.all?(expected, &(&1 in services)), do: :passed, else: {:failed, "empty_runtime"}
  end

  @spec render_report(keyword()) :: String.t()
  def render_report(opts) when is_list(opts) do
    results = Enum.map(Keyword.get(opts, :results, []), &normalize_result/1)
    status = Keyword.get(opts, :status, aggregate_status(results))

    lines =
      [
        "Nix-Swarm release evidence",
        "===========================",
        "timestamp: #{Keyword.get(opts, :timestamp, "unknown")}",
        "revision: #{Keyword.get(opts, :revision, "unknown")}",
        "clean: #{Keyword.get(opts, :clean, "unknown")}",
        "status: #{status}",
        "",
        "results:"
      ] ++ Enum.map(results, &format_result/1)

    Enum.join(lines, "\n") <> "\n"
  end

  def redact(value) when is_binary(value) do
    value
    |> String.replace(~r/-----BEGIN [^-]+-----.*?-----END [^-]+-----/s, "[REDACTED PRIVATE KEY]")
    |> String.replace(
      ~r/(?i)(authorization\s*:\s*bearer|bearer|cookie|secret|token|password|credential)([=: ]+)[^\s,;]+/,
      "\\1\\2[REDACTED]"
    )
    |> String.replace(~r/[A-Za-z0-9+\/_-]{40,}={0,2}/, "[REDACTED]")
    |> String.replace(~r/[A-Fa-f0-9]{32,}/, "[REDACTED]")
    |> String.slice(0, @max_detail)
  end

  def redact(value), do: value |> inspect() |> redact()

  defp normalize_result({name, status, detail}),
    do: %{
      name: name,
      status: status,
      required: true,
      command: [],
      exit_status: nil,
      duration_ms: nil,
      detail: detail
    }

  defp normalize_result(result),
    do:
      Map.merge(
        %{required: true, command: [], exit_status: nil, duration_ms: nil, detail: ""},
        result
      )

  defp format_result(result) do
    command = Enum.join(result.command, " ")

    "- #{result.name}: #{result.status} | command: #{command} | exit_status: #{inspect(result.exit_status)} | duration_ms: #{inspect(result.duration_ms)} — #{redact(result.detail)}"
  end
end
