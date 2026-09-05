defmodule NixSwarmWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :nix_swarm_web,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 65]],
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {NixSwarmWeb.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8.13"},
      {:phoenix_live_view, "~> 1.2.11"},
      {:bandit, "~> 1.12.5"},
      {:plug, "~> 1.19"},
      {:telemetry, "~> 1.3"},
      {:phoenix_pubsub, "~> 2.2"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
