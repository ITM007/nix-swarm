defmodule NixSwarmClusterDeployTest do
  use ExUnit.Case, async: true

  test "ensure previews native activation through Deploy" do
    deploy_fun = fn opts -> deploy_result(opts, "node-a") end

    result =
      NixSwarm.Cluster.Ensure.run(
        [hosts: ["root@example-node-a.local"], dry_run: true],
        deploy_fun
      )

    assert result.ok
    assert [%{node: "node-a", status: :ok, action: :preview}] = result.nodes
    assert result.deploy.dry_run
  end

  test "rebuild previews native switch through Deploy" do
    deploy_fun = fn opts -> deploy_result(opts, "node-b") end

    result =
      NixSwarm.Cluster.Rebuild.run(
        [hosts: ["root@example-node-b.local"], dry_run: true],
        deploy_fun
      )

    assert result.ok
    assert [%{hostname: "node-b", status: :ok, action: :preview}] = result.nodes
  end

  test "compatibility commands normalize invalid deployment input" do
    assert %{ok: false, nodes: [], error: error} =
             NixSwarm.Cluster.Ensure.run(source: "/definitely/missing/nix-swarm")

    assert error =~ "source directory does not exist"

    assert %{ok: false, nodes: []} =
             NixSwarm.Cluster.Rebuild.run(source: "/definitely/missing/nix-swarm")
  end

  defp deploy_result(opts, configuration) do
    %{
      dry_run: Keyword.fetch!(opts, :dry_run),
      results: [
        %{
          configuration: configuration,
          host: opts |> Keyword.fetch!(:hosts) |> hd()
        }
      ]
    }
  end
end
