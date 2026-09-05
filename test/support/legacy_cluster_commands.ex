defmodule NixSwarm.Cluster.Ensure do
  @moduledoc """
  Compatibility test helper for the retired cluster ensure command.
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

defmodule NixSwarm.Cluster.Rebuild do
  @moduledoc """
  Compatibility test helper for the retired cluster rebuild command.
  """

  alias NixSwarm.Deploy

  def run(opts \\ [], deploy_fun \\ &Deploy.run/1) when is_function(deploy_fun, 1) do
    deploy = deploy_fun.(opts)

    %{
      ok: true,
      deploy: deploy,
      nodes:
        Enum.map(deploy.results, fn result ->
          %{
            hostname: result.configuration,
            host: result.host,
            status: :ok,
            action: if(deploy.dry_run, do: :preview, else: :switch),
            output: Map.get(result, :rebuild_output, "")
          }
        end)
    }
  rescue
    error in [ArgumentError, RuntimeError] ->
      %{ok: false, nodes: [], error: Exception.message(error)}
  end
end
