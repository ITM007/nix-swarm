defmodule NixSwarm do
  @moduledoc """
  Leaderless Nix-defined service orchestration for small NixOS clusters.
  """

  @operator_command "swarm"

  def config do
    NixSwarm.Config.current()
  end

  def app_version do
    case Application.spec(:nix_swarm, :vsn) do
      nil -> "0.1.4"
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn -> to_string(vsn)
    end
  end

  def release_label do
    "v#{app_version()}"
  end

  def operator_command do
    @operator_command
  end

  def operator_launch(target \\ "NODE") do
    "#{operator_command()} --target #{target}"
  end
end
