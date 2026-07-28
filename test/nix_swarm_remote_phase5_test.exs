defmodule NixSwarmRemotePhase5Test do
  use ExUnit.Case, async: true

  test "diagnostics classify common bootstrap failures with actionable fixes" do
    remote = %{target: "nix-swarm@node-a", ssh_host: "root@node-a"}

    cases = [
      {:ssh_failed, "SSH authentication/host-key failure", "known_hosts"},
      {:sudo_interactive, "noninteractive privilege failure", "passwordless sudo"},
      {:wrong_architecture, "architecture mismatch", "architecture"},
      {:low_disk, "insufficient disk space", "free disk"},
      {:non_nixos, "not a NixOS target", "NixOS"},
      {:missing_query, "query helper is unavailable", "nix-swarm-query"},
      {:protocol_incompatible, "query protocol is incompatible", "protocol"}
    ]

    Enum.each(cases, fn {reason, check, fix} ->
      diagnostic = NixSwarm.Remote.diagnostic_for_failure(remote, reason)

      assert Enum.any?(
               NixSwarm.Remote.diagnostic_checks(diagnostic),
               &String.contains?(&1.detail, check)
             )

      assert NixSwarm.Remote.format_doctor_report(diagnostic) =~ fix
    end)
  end
end
