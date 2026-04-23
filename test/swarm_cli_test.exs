defmodule SwarmCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "longname cli node identity uses the local host instead of the target host" do
    identity =
      Swarm.CLI.cli_node_identity("swarm@192.168.1.226", nil, fn _target_host ->
        "192.168.1.121"
      end)

    assert identity.mode == :longnames
    assert Atom.to_string(identity.name) =~ "@192.168.1.121"
    refute Atom.to_string(identity.name) =~ "@192.168.1.226"
  end

  test "run returns a formatted error when --name is invalid for a longname target" do
    assert {:error, message} =
             Swarm.CLI.run([
               "--target",
               "swarm@192.168.1.226",
               "--cookie",
               "secret-cookie",
               "--name",
               "swarmctl",
               "status"
             ])

    assert message == "--name must include @HOST when connecting to a longname target"
  end

  test "help output includes a short description for each command" do
    output =
      capture_io(fn ->
        assert :ok == Swarm.CLI.run(["help"])
      end)

    plain_output = strip_ansi(output)

    assert plain_output =~ "export SWARM_COOKIE_FILE=./secrets/swarm.cookie"
    assert plain_output =~ "Show the effective CLI and Nix default values."
    assert plain_output =~ "Show cluster status, placements, and per-node unit state."
    assert plain_output =~ "Show one compact line per live node and service."
    assert plain_output =~ "Show configured peers and currently live nodes."
    assert plain_output =~ "Show an ASCII map of nodes and service slot ownership."
    assert plain_output =~ "Diagnose remote-node reachability, naming, ports, and Swarm RPC."
    assert plain_output =~ "Restart the named service on every live owner node."
    assert plain_output =~ "Show recent logs for each live owner of the service."
    assert plain_output =~ "Force an immediate reconciliation across live nodes."
    assert plain_output =~ "Generate a machine bootstrap file for a new Swarm node."
    assert plain_output =~ "Generate a machine file and deploy it to the new host over SSH."

    assert plain_output =~
             "Validate the cluster config and print the rollout plan for all machine files."

    assert plain_output =~ "Validate, preview, and apply to all machine files by default."
    assert plain_output =~ "Override the source checkout or remote repo path used during apply."
    assert plain_output =~ "remote commands can target any reachable Swarm node"

    assert plain_output =~
             "remote commands need --cookie, --cookie-file, SWARM_COOKIE, or SWARM_COOKIE_FILE"
  end

  test "defaults output shows current apply and Nix defaults" do
    output =
      capture_io(fn ->
        assert :ok == Swarm.CLI.run(["defaults", "--source", "."])
      end)

    plain_output = strip_ansi(output)

    assert plain_output =~ "defaults"
    assert plain_output =~ "hosts"
    assert plain_output =~ "nixos-2, nixos-3"
    assert plain_output =~ "default behavior"
    assert plain_output =~ "validate -> preview plan -> apply all hosts"
    assert plain_output =~ "services.swarm.package"
    assert plain_output =~ "import ./package.nix { inherit pkgs; }"

    assert plain_output =~ "cookie"

    assert plain_output =~
             "required via --cookie, --cookie-file, SWARM_COOKIE, or SWARM_COOKIE_FILE"

    assert plain_output =~ "services.swarm.openFirewall"
    assert plain_output =~ "false"
    assert plain_output =~ "services.swarm.services.<name>.replicas"
    assert plain_output =~ "1"
  end

  test "remote commands reject missing cookies" do
    assert {:error, message} =
             Swarm.CLI.run([
               "--target",
               "swarm@192.168.1.226",
               "status"
             ])

    assert message =~ "missing cookie for remote command"
  end

  test "remote commands accept --cookie-file" do
    path = Path.join(System.tmp_dir!(), "swarm-cli-cookie-#{System.unique_integer([:positive])}")
    File.write!(path, "secret-cookie\n")

    assert {:error, message} =
             Swarm.CLI.run([
               "--target",
               "swarm@192.168.1.226",
               "--cookie-file",
               path,
               "--name",
               "swarmctl",
               "status"
             ])

    assert message == "--name must include @HOST when connecting to a longname target"

    File.rm_rf!(path)
  end

  test "remote commands accept SWARM_COOKIE" do
    previous = System.get_env("SWARM_COOKIE")
    System.put_env("SWARM_COOKIE", "secret-cookie")

    on_exit(fn ->
      if previous do
        System.put_env("SWARM_COOKIE", previous)
      else
        System.delete_env("SWARM_COOKIE")
      end
    end)

    assert {:error, message} =
             Swarm.CLI.run([
               "--target",
               "swarm@192.168.1.226",
               "--name",
               "swarmctl",
               "status"
             ])

    assert message == "--name must include @HOST when connecting to a longname target"
  end

  test "formatted connection errors include checks and fixes" do
    diagnostic = %{
      target: "swarm@192.168.1.226",
      target_host: "192.168.1.226",
      target_mode: :longnames,
      cli_name: nil,
      cli_node: :"swarmctl-1@192.168.1.121",
      cookie_source: :provided,
      local_ip_candidates: ["192.168.1.121"],
      target_resolution: %{
        status: :ok,
        host: "192.168.1.226",
        detail: "192.168.1.226"
      },
      target_port_checks: [
        %{label: "target epmd TCP port 4369", status: :ok, detail: "reachable"},
        %{
          label: "target Swarm distribution TCP port 4370",
          status: :error,
          detail: ":econnrefused"
        }
      ],
      connect_result: false,
      remote_probe: %{
        remote_self: %{
          status: :info,
          detail: "skipped because the distributed Erlang connection failed"
        },
        cluster_members: %{
          status: :info,
          detail: "skipped because the distributed Erlang connection failed"
        }
      }
    }

    message = Swarm.CLI.format_connection_error(diagnostic)

    assert message =~ "connection context:"
    assert message =~ "local CLI node: swarmctl-1@192.168.1.121"
    assert message =~ "[fail] target Swarm distribution TCP port 4370: :econnrefused"
    assert message =~ "Make sure the target allows TCP 4370 for distributed Erlang."
    assert message =~ "Retry with `--name swarmctl@192.168.1.121`"

    assert message =~
             "rerun `swarm --target swarm@192.168.1.226 doctor` with the same cookie source"
  end

  defp strip_ansi(output) do
    Regex.replace(~r/\e\[[\d;]*m/, output, "")
  end
end
