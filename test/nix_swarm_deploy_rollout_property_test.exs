defmodule NixSwarmDeployRolloutPropertyTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Deploy.Rollout

  test "rollout stages preserve every target and respect every bounded batch width" do
    targets =
      for {classification, host} <-
            Enum.with_index(
              [
                :new_nixos_host,
                :existing_outdated,
                :existing_in_sync,
                :existing_outdated,
                :new_nixos_host
              ],
              1
            ) do
        %{
          host: "root@node-#{host}",
          configuration: "node-#{host}",
          classification: classification
        }
      end

    for max_unavailable <- 1..4 do
      rollout = Rollout.plan(targets, max_unavailable: max_unavailable)
      flattened = List.flatten(rollout.stages)

      assert Enum.map(flattened, & &1.host) |> Enum.sort() ==
               Enum.map(targets, & &1.host) |> Enum.sort()

      assert Enum.all?(rollout.stages, &(length(&1) <= max_unavailable))
      assert Enum.all?(flattened, &(&1.classification not in [:incompatible, :unreachable]))
    end
  end
end
