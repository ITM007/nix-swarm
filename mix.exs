defmodule Swarm.MixProject do
  use Mix.Project

  def project do
    [
      app: :swarm,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Swarm.CLI],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Swarm.Application, []}
    ]
  end

  defp deps do
    []
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
