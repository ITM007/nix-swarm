defmodule NixSwarm.MixProject do
  use Mix.Project

  @version Path.expand("VERSION", __DIR__) |> File.read!() |> String.trim()

  def project do
    [
      app: :nix_swarm,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [infer_signatures: true, module_definition: :interpreted],
      test_elixirc_options: [infer_signatures: true],
      test_coverage: [summary: [threshold: 65]],
      start_permanent: Mix.env() == :prod,
      escript: [main_module: NixSwarm.CLI],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :os_mon, :crypto, :public_key, :ssl],
      mod: {NixSwarm.Application, []}
    ]
  end

  defp deps do
    [
      {:ex_ratatui, "~> 0.11.1"},
      {:telemetry, "~> 1.3"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
