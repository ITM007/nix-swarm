defmodule NixSwarm.ReleaseEvidenceScript do
  alias NixSwarm.ReleaseEvidence

  @commands [
    {:format, "mix", ["format", "--check-formatted"]},
    {:compile, "mix", ["compile", "--warnings-as-errors"]},
    {:tests, "mix", ["test", "--warnings-as-errors", "--cover"]},
    {:flake_check, "nix", ["flake", "check", "--no-build", "--no-write-lock-file"]},
    {:docker_status, "docker", ["compose", "ps"]}
  ]

  def run do
    output_path = output_path(System.argv)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    revision = git_revision()
    results = Enum.map(@commands, &run_command/1)
    report = ReleaseEvidence.render_report(timestamp: timestamp, revision: revision, results: results)
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, report)
    IO.write(report)
    IO.puts("evidence written to #{output_path}")

    if Enum.any?(results, fn {_name, status, _detail} -> status == :failed end) do
      System.halt(1)
    end
  end

  defp run_command({name, executable, args}) do
    case System.find_executable(executable) do
      nil -> {name, :unavailable, "#{executable} is not installed"}
      _path ->
        {output, status} = System.cmd(executable, args, stderr_to_stdout: true)
        result = if status == 0, do: :passed, else: :failed
        {name, result, output |> String.trim() |> String.slice(0, 4_000)}
    end
  end

  defp git_revision do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} -> String.trim(revision)
      {error, _} -> String.trim(error)
    end
  end

  defp output_path(["--output", path | _]), do: Path.expand(path)
  defp output_path(_), do: Path.expand("_build/release-evidence.txt")
end

NixSwarm.ReleaseEvidenceScript.run()
