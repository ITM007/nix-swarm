defmodule NixSwarmDeployRollbackReportTest do
  use ExUnit.Case, async: false

  alias NixSwarm.Deploy

  @host "root@node-a"

  defp manifest do
    %{
      "schemaVersion" => 1,
      "nodes" => %{
        "nix-swarm@node-a" => %{
          "availability" => "active",
          "deployHost" => @host,
          "nixosConfiguration" => "node-a"
        }
      }
    }
  end

  defp opts(runner) do
    source = Path.expand("..", __DIR__)

    [
      source: source,
      deployment_manifest: manifest(),
      health_check: false,
      git_status_fun: fn _source -> :clean end,
      runner: runner,
      probe_fun: fn _target, _timeout ->
        %{
          ssh: %{ok: true},
          nixos: %{ok: true},
          privilege: %{ok: true},
          architecture: %{ok: true},
          disk: %{ok: true},
          credential: %{ok: true, state: :present},
          service: %{ok: true, state: :active},
          query: %{ok: true, state: :in_sync},
          protocol: %{ok: true, state: :compatible}
        }
      end
    ]
  end

  # Fails activation (and optionally the automatic rollback) while letting
  # validation builds pass.
  defp failing_runner(rollback_fails?) do
    fn executable, args, _env, _timeout ->
      joined = Enum.join(args, " ")

      cond do
        executable == "nixos-rebuild" and joined =~ "switch" and not (joined =~ "--rollback") ->
          raise "activation exploded"

        rollback_fails? and executable == "nixos-rebuild" and joined =~ "--rollback" ->
          raise "rollback exploded"

        true ->
          ""
      end
    end
  end

  test "a failed activation reports rolled_back and the attempted host" do
    error =
      assert_raise RuntimeError, ~r/deployment failed in stage 1/, fn ->
        Deploy.run(opts(failing_runner(false)))
      end

    assert error.message =~ "activation exploded"
    assert error.message =~ @host
    assert error.message =~ "automatically rolled back 1 attempted host(s)"
    assert error.message =~ "rollback_status=rolled_back"
  end

  test "a rollback failure is reported explicitly as rollback_failed" do
    error =
      assert_raise RuntimeError, ~r/deployment failed in stage 1/, fn ->
        Deploy.run(opts(failing_runner(true)))
      end

    assert error.message =~ "activation exploded"
    assert error.message =~ "automatic rollback also failed"
    assert error.message =~ "rollback exploded"
    assert error.message =~ "rollback_status=rollback_failed"
  end

  test "a rollback failure still names the attempted and unattempted hosts" do
    error =
      assert_raise RuntimeError, ~r/deployment failed in stage 1/, fn ->
        Deploy.run(opts(failing_runner(true)))
      end

    assert error.message =~ "attempted=[\"#{@host}\"]"
    assert error.message =~ "unattempted=[]"
  end
end
