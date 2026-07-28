defmodule NixSwarm.ReleaseEvidence.Collector do
  @moduledoc """Dependency-injected release gate collector."""

  alias NixSwarm.ReleaseEvidence

  @default_gates [
    {:format, ["mix", "format", "--check-formatted"]},
    {:compile, ["mix", "compile", "--warnings-as-errors"]},
    {:hex_audit, ["mix", "hex.audit"]},
    {:tests_with_coverage, ["mix", "test", "--warnings-as-errors", "--cover"]},
    {:flake_check, ["nix", "flake", "check", "--no-build", "--no-write-lock-file"]},
    {:nixos_vm, ["nix", "build", ".#checks.x86_64-linux.nixos-vm", "--no-link"]},
    {:operator_smoke, ["nix", "build", ".#checks.x86_64-linux.operator-smoke", "--no-link"]},
    {:starter_syntax, ["nix", "build", ".#checks.x86_64-linux.starter-syntax", "--no-link"]},
    {:otp_integration, ["mix", "run", "--no-start", "scripts/verify_cluster.exs"]},
    {:docker_standard_matrix, ["docker", "compose", "ps"]},
    {:docker_hardened_matrix, ["docker", "compose", "ps", "--profile", "hardened"]},
    {:docker_reset, ["docker", "compose", "ps"]},
    {:clean_checkout, ["git", "status", "--short"]}
  ]

  def default_gates, do: @default_gates

  def collect(opts \\ []) do
    runner = Keyword.get(opts, :runner, &run_command/1)
    revision = Keyword.get(opts, :revision, &default_revision/0)
    clean? = Keyword.get(opts, :clean?, &default_clean?/0)
    writer = Keyword.get(opts, :writer, &default_writer/2)
    clock = Keyword.get(opts, :clock, {&monotonic/0, &monotonic/0})
    gates = Keyword.get(opts, :gates, @default_gates)
    require_docker = Keyword.get(opts, :require_docker, false)
    docker_services = Keyword.get(opts, :docker_services, ["node-a", "node-b", "node-c", "operator"])
    started = elem(clock, 0).()

    results = Enum.map(gates, fn {name, command} ->
      collect_gate(name, command, runner, clean?, clock, require_docker, docker_services)
    end)

    status = ReleaseEvidence.aggregate_status(results)
    report = ReleaseEvidence.render_report(timestamp: DateTime.utc_now() |> DateTime.to_iso8601(), revision: revision.(), clean: clean?.(), status: status, results: results)
    writer.(Keyword.get(opts, :output, "_build/release-evidence.txt"), report)
    %{status: status, results: results, report: report, duration_ms: elapsed(clock, started)}
  end

  defp collect_gate(:clean_checkout, command, _runner, clean?, clock, _required, _services) do
    result(:clean_checkout, command, if(clean?.(), do: :passed, else: :failed), if(clean?.(), do: "clean", else: "dirty_checkout"), nil, clock)
  end

  defp collect_gate(name, command, runner, _clean?, clock, require_docker, services) do
    required = not docker_gate?(name) or require_docker
    case runner.(command) do
      {:unavailable, detail} -> result(name, command, :unavailable, detail, required, clock)
      {output, exit_status} ->
        {status, detail} = runtime_result(name, output, exit_status, services)
        result(name, command, status, detail, required, clock, exit_status)
    end
  rescue
    error -> result(name, command, :unavailable, Exception.message(error), required, clock)
  end

  defp runtime_result(name, output, 0, services) when name in [:docker_standard_matrix, :docker_hardened_matrix] do
    case ReleaseEvidence.validate_runtime(name, output, expected_services: services) do
      :passed -> {:passed, String.trim(output)}
      {:failed, detail} -> {:failed, detail}
    end
  end
  defp runtime_result(_name, output, 0, _services), do: {:passed, String.trim(output)}
  defp runtime_result(_name, output, status, _services), do: {:failed, "exit_status=#{status} #{String.trim(output)}"}

  defp result(name, command, status, detail, required, clock, exit_status \\ nil) do
    %{name: name, status: status, required: required, command: command, exit_status: exit_status, duration_ms: elapsed(clock, elem(clock, 0).()), detail: detail}
  end

  defp docker_gate?(name), do: name in [:docker_standard_matrix, :docker_hardened_matrix, :docker_reset]
  defp elapsed({_, stop}, started), do: max(0, stop.() - started)
  defp monotonic, do: System.monotonic_time(:millisecond)

  defp run_command([executable | args]) do
    case System.find_executable(executable) do
      nil -> {:unavailable, "#{executable} is not installed"}
      path -> System.cmd(path, args, stderr_to_stdout: true)
    end
  end

  defp default_revision do
    case run_command(["git", "rev-parse", "HEAD"]) do
      {revision, 0} -> String.trim(revision)
      {error, _} -> String.trim(error)
      {:unavailable, error} -> error
    end
  end

  defp default_clean? do
    case run_command(["git", "status", "--porcelain", "--untracked-files=no"]) do
      {output, 0} -> String.trim(output) == ""
      _ -> false
    end
  end

  defp default_writer(path, report) do
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, report)
    IO.write(report)
  end
end
