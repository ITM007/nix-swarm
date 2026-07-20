defmodule NixSwarm.Cluster.Rebuild do
  @moduledoc """
  Compatibility entry point for cluster-wide native NixOS deployment.

  Host discovery, validation, closure copying, and activation are delegated to
  `NixSwarm.Deploy`; this module does not parse Nix source or execute remote
  shell scripts.
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
