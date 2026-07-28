defmodule NixSwarmDeployPreflightTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Deploy.{Preflight, Target}

  defp target, do: %Target{host: "root@node-c", configuration: "node-c", node: "nix-swarm@node-c"}

  defp healthy(overrides \\ %{}) do
    Map.merge(
      %{
        ssh: %{ok: true},
        nixos: %{ok: true},
        privilege: %{ok: true},
        architecture: %{ok: true},
        disk: %{ok: true},
        credential: %{ok: true, state: :present},
        service: %{ok: true, state: :active},
        query: %{ok: true, state: :in_sync}
      },
      overrides
    )
  end

  for {name, overrides, expected} <- [
        {"new NixOS host",
         %{
           service: %{ok: true, state: :missing},
           query: %{ok: true, state: :missing},
           credential: %{ok: true, state: :missing}
         }, :new_nixos_host},
        {"installed inactive host", %{service: %{ok: true, state: :inactive}},
         :installed_inactive},
        {"unqueryable host", %{query: %{ok: true, state: :unqueryable}}, :installed_unqueryable},
        {"in-sync host", %{}, :existing_in_sync},
        {"outdated host", %{query: %{ok: true, state: :outdated}}, :existing_outdated},
        {"draining host", %{query: %{ok: true, state: :draining}}, :draining},
        {"maintenance host", %{query: %{ok: true, state: :maintenance}}, :maintenance}
      ] do
    test "classifies #{name}" do
      result = Preflight.classify(target(), healthy(unquote(Macro.escape(overrides))))
      assert result.classification == unquote(expected)
      assert result.blockers == []
    end
  end

  test "hard blockers produce incompatible classification" do
    result = Preflight.classify(target(), healthy(%{ssh: %{ok: false}, privilege: %{ok: false}}))
    refute Preflight.ready?(result)
    assert result.classification == :incompatible
    assert Enum.any?(result.blockers, &String.contains?(&1, "SSH"))
    assert Enum.any?(result.blockers, &String.contains?(&1, "privilege"))
  end

  test "mismatched credentials fail closed without retaining secret fields" do
    result =
      Preflight.classify(
        target(),
        healthy(%{credential: %{ok: false, state: :mismatched, contents: "super-secret"}})
      )

    refute Preflight.ready?(result)
    refute inspect(result) =~ "super-secret"
    assert result.classification == :incompatible
  end

  test "missing credential is a warning and does not expose contents" do
    result =
      Preflight.classify(
        target(),
        healthy(%{credential: %{ok: true, state: :missing, value: "cookie"}})
      )

    assert result.classification == :installed_inactive

    assert result.warnings == [
             "shared credential is missing and must be enrolled before activation"
           ]

    refute inspect(result) =~ "cookie"
  end

  test "run uses a bounded injected probe adapter" do
    parent = self()

    result =
      Preflight.run(target(),
        timeout_ms: 1234,
        probe_fun: fn received_target, timeout ->
          send(parent, {:probed, received_target.host, timeout})
          healthy()
        end
      )

    assert_receive {:probed, "root@node-c", 1234}
    assert result.classification == :existing_in_sync
  end

  test "Deploy.preflight classifies evaluated deployment targets without mutation" do
    source = Path.expand("..", __DIR__)

    results =
      NixSwarm.Deploy.preflight(
        [
          source: source,
          hosts: ["root@example-node-a.local"],
          configurations: %{"root@example-node-a.local" => "example-node-a"}
        ],
        fn _target, _timeout -> healthy() end
      )

    assert [%Target{classification: :existing_in_sync, host: "root@example-node-a.local"}] =
             results
  end
end
