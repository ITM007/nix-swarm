defmodule NixSwarm.Cluster.Ensure do
  @moduledoc """
  Activates every configured machine through the native NixOS deployment path.

  This command intentionally does not parse or rewrite Nix files on a target.
  The local flake must contain a complete `nixosConfigurations.<host>` output,
  including hardware configuration and the Nix-Swarm module.
  """

  alias NixSwarm.Deploy

  def run(opts \\ [], deploy_fun \\ &Deploy.run/1) when is_function(deploy_fun, 1) do
    deploy =
      opts
      |> Keyword.drop([:cookie, :force])
      |> deploy_fun.()

    %{
      ok: true,
      deploy: deploy,
      nodes:
        Enum.map(deploy.results, fn result ->
          %{
            node: result.configuration,
            host: result.host,
            status: :ok,
            action: if(deploy.dry_run, do: :preview, else: :activate),
            result: :ok,
            message: "activated from the local flake"
          }
        end)
    }
  rescue
    error in [ArgumentError, RuntimeError] ->
      %{
        ok: false,
        nodes: [],
        error: Exception.message(error)
      }
  end
end
