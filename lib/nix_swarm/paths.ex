defmodule NixSwarm.Paths do
  @moduledoc false

  @config_dir ".config/nix-swarm"

  def default_source do
    cond do
      env_source = System.get_env("NIX_SWARM_SOURCE") ->
        Path.expand(env_source)

      project_root?(".") ->
        Path.expand(".")

      true ->
        home_source()
    end
  end

  def home_source do
    Path.join(System.user_home!(), @config_dir)
  end

  def source_root?(path) do
    expanded = Path.expand(path)

    File.exists?(Path.join(expanded, "mix.exs")) and
      File.dir?(Path.join(expanded, "lib")) and
      File.exists?(Path.join(expanded, "nix/nix-swarm/module.nix"))
  end

  def project_root?(path) do
    expanded = Path.expand(path)

    File.exists?(Path.join(expanded, "mix.exs")) and
      File.exists?(Path.join(expanded, "nix/nix-swarm/module.nix"))
  end
end
