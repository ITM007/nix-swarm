defmodule NixSwarm.MixProject do
  use Mix.Project

  def project do
    [
      app: :nix_swarm,
      version: "0.1.2",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      escript: [main_module: NixSwarm.CLI],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :os_mon],
      mod: {NixSwarm.Application, []}
    ]
  end

  defp deps do
    [
      {:ex_ratatui, "~> 0.8"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
