defmodule Swarm do
  @moduledoc """
  Leaderless Nix-defined service orchestration for small NixOS clusters.
  """

  def config do
    Swarm.Config.current()
  end
end
