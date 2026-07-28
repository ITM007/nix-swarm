defmodule NixSwarm.ReleaseEvidenceScript do
  alias NixSwarm.ReleaseEvidence
  alias NixSwarm.ReleaseEvidence.Collector

  def run(argv \\ System.argv) do
    output = output_path(argv)
    require_docker = "--require-docker" in argv
    result = Collector.collect(output: output, require_docker: require_docker)
    IO.puts("evidence written to #{output}")
    if ReleaseEvidence.release_success?(result.results), do: :ok, else: System.halt(1)
  end

  defp output_path(["--output", path | _]), do: Path.expand(path)
  defp output_path([arg | rest]) when arg != "--require-docker", do: output_path(rest)
  defp output_path(_), do: Path.expand("_build/release-evidence.txt")
end

NixSwarm.ReleaseEvidenceScript.run()
