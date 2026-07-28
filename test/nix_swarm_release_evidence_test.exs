defmodule NixSwarm.ReleaseEvidenceTest do
  use ExUnit.Case, async: true

  alias NixSwarm.ReleaseEvidence

  test "failure matrix names every phase 6 acceptance scenario" do
    ids = ReleaseEvidence.failure_matrix() |> Enum.map(& &1.id)

    assert length(ids) >= 18
    assert :missing_credential in ids
    assert :protocol_incompatible in ids
    assert :canary_failure in ids
    assert :process_death in ids
    assert :private_firewall in ids
    assert :disko_explicit_disk in ids
  end

  test "renders reproducible evidence without secret material" do
    report =
      ReleaseEvidence.render_report(
        timestamp: "2026-07-28T00:00:00Z",
        revision: "abc123",
        results: [{:mix_test, :passed, "241 passed; cookie=0123456789abcdef0123456789abcdef"}]
      )

    assert report =~ "Nix-Swarm release evidence"
    assert report =~ "abc123"
    assert report =~ "[REDACTED]"
    refute report =~ "0123456789abcdef0123456789abcdef"
    assert report =~ "mix_test: passed"
  end

  test "aggregate status fails closed for required unavailable and skipped gates" do
    results = [
      %{name: :format, status: :passed, required: true},
      %{name: :docker, status: :unavailable, required: true},
      %{name: :optional_docker, status: :unavailable, required: false}
    ]

    assert ReleaseEvidence.aggregate_status(results) == :incomplete
    refute ReleaseEvidence.release_success?(results)
  end

  test "empty runtime is not a pass" do
    assert ReleaseEvidence.validate_runtime(:docker, [], expected_services: ["node-a"]) ==
             {:failed, "empty_runtime"}

    assert ReleaseEvidence.validate_runtime(:docker, ["node-a"], expected_services: ["node-a"]) ==
             :passed

    assert ReleaseEvidence.validate_runtime(:docker, ["node-a"],
             expected_services: ["node-a", "node-b"]
           ) ==
             {:failed, "empty_runtime"}
  end

  test "redacts credential labels, bearer tokens, private keys and bounded secrets" do
    detail =
      "cookie=secret cookie-value; Authorization: Bearer abc.def.ghi " <>
        "-----BEGIN PRIVATE KEY-----\nprivate\n-----END PRIVATE KEY----- " <>
        "token=0123456789abcdef0123456789abcdef " <>
        String.duplicate("A", 100)

    redacted = ReleaseEvidence.redact(detail)

    refute redacted =~ "secret cookie-value"
    refute redacted =~ "abc.def.ghi"
    refute redacted =~ "BEGIN PRIVATE KEY"
    refute redacted =~ String.duplicate("A", 100)
    assert String.length(redacted) <= 4_000
  end

  test "renders gate metadata and clean checkout state" do
    report =
      ReleaseEvidence.render_report(
        timestamp: "2026-07-28T00:00:00Z",
        revision: "abc123",
        clean: true,
        results: [
          %{
            name: :format,
            status: :passed,
            command: ["mix", "format"],
            exit_status: 0,
            duration_ms: 12,
            detail: "ok"
          }
        ]
      )

    assert report =~ "status: passed"
    assert report =~ "clean: true"
    assert report =~ "command: mix format"
    assert report =~ "exit_status: 0"
    assert report =~ "duration_ms: 12"
  end
end
