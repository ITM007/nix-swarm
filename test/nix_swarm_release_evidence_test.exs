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
end
