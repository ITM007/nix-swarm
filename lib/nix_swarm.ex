defmodule NixSwarm do
  @moduledoc """
  Leaderless Nix-defined service orchestration for small NixOS clusters.
  """

  def config do
    NixSwarm.Config.current()
  end
end
