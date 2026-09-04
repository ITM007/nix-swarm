defmodule NixSwarm.Deploy.ProbeAdapterTest do
  use ExUnit.Case, async: false

  alias NixSwarm.Deploy.{ProbeAdapter, Target}
  alias NixSwarm.QueryProtocol

  @timeout_ms 2_000

  defp target(host \\ "root@node-a") do
    %Target{host: host, configuration: "node-a"}
  end

  # Builds a command_fun that answers each probe marker with canned output.
  defp scripted_fun(markers, default \\ {"", 0}) do
    fn _executable, args ->
      command = args |> List.last()

      Enum.find_value(markers, default, fn {marker, response} ->
        if String.contains?(command, marker), do: response
      end)
    end
  end

  defp encode(%{} = response) do
    {:ok, encoded} = QueryProtocol.encode_response(response)
    encoded
  end

  test "returns an SSH failure when the transport is unreachable" do
    command_fun = fn _executable, _args -> {"ssh: connection refused", 255} end
    probes = ProbeAdapter.probe(target(), @timeout_ms, command_fun)
    assert probes.ssh == {:error, "ssh: connection refused (exit 255)"}
  end

  test "detects a reachable NixOS host with deployment privilege" do
    probes = ProbeAdapter.probe(target(), @timeout_ms, scripted_fun([]))
    assert probes.ssh == :ok
    assert probes.nixos == :ok
    assert probes.privilege == :ok
  end

  test "detects a non-NixOS target" do
    fun = scripted_fun([{"nixos-version", {"command not found", 127}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert probes.nixos == {:error, "command not found"}
  end

  test "detects missing noninteractive privilege" do
    fun = scripted_fun([{"sudo -n", {"sudo: a password is required", 1}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert match?({:error, _message}, probes.privilege)
  end

  test "matches the target architecture against the local build host" do
    expected = ProbeAdapter.local_architecture()
    fun = scripted_fun([{"uname -m", {expected <> "\n", 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert probes.architecture == %{ok: true, remote: expected, expected: expected}
  end

  test "flags a target architecture mismatch" do
    fun = scripted_fun([{"uname -m", {"aarch64\n", 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert probes.architecture.ok == false
  end

  test "flags insufficient free disk space" do
    fun = scripted_fun([{"df -Pk /nix", {"2048\n", 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert probes.disk == %{ok: false, free_kib: 2048}
  end

  test "accepts sufficient free disk space" do
    fun = scripted_fun([{"df -Pk /nix", {"52428800\n", 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert probes.disk.ok == true
  end

  test "reports a missing credential when the remote file is absent" do
    fun = scripted_fun([{"sha256sum", {"__NIX_SWARM_MISSING__", 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun, secret_file: fixture_cookie())
    assert probes.credential == :missing
  end

  test "reports matching and mismatched credentials without leaking contents" do
    path = fixture_cookie()
    content = File.read!(path) |> String.trim()
    digest = content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    matching = scripted_fun([{"sha256sum", {digest, 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, matching, secret_file: path)
    assert probes.credential == :present

    mismatched = scripted_fun([{"sha256sum", {String.duplicate("a", 64), 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, mismatched, secret_file: path)
    assert probes.credential == :mismatched
  end

  test "reports a running service unit" do
    fun = scripted_fun([{"is-active", {"running\n", 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert probes.service == :running
  end

  test "reports an inactive but installed service unit" do
    fun = scripted_fun([{"is-active", {"inactive\n", 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert probes.service == :inactive
  end

  test "reports a missing service unit" do
    fun = scripted_fun([{"is-active", {"missing\n", 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert probes.service == :missing
  end

  test "reports a reachable query socket" do
    response = encode(%{queried_node: "nix-swarm@node-a", live_nodes: ["nix-swarm@node-a"]})

    fun = scripted_fun([{"nix-swarm-query", {response, 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert probes.query.state == :active
  end

  test "reports an unqueryable socket without leaking the response" do
    fun = scripted_fun([{"nix-swarm-query", {"not a response", 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert probes.query == %{ok: true, state: :unqueryable}
  end

  test "reports protocol compatibility from remote capabilities" do
    expected = QueryProtocol.protocol_version()
    response = encode(%{capabilities: %{protocol_version: expected}})

    fun = scripted_fun([{"nix-swarm-query", {response, 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert probes.protocol == %{ok: true, state: :compatible}
  end

  test "reports an incompatible remote protocol" do
    response = encode(%{capabilities: %{protocol_version: 1}})

    fun = scripted_fun([{"nix-swarm-query", {response, 0}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert probes.protocol == %{ok: true, state: :incompatible}
  end

  test "returns an unknown protocol when the remote cannot answer" do
    fun = scripted_fun([{"nix-swarm-query", {"", 127}}])
    probes = ProbeAdapter.probe(target(), @timeout_ms, fun)
    assert probes.protocol == %{ok: true, state: :unknown}
  end

  defp fixture_cookie do
    path =
      Path.join(System.tmp_dir!(), "nix-swarm-probe-#{System.unique_integer([:positive])}.cookie")

    File.write!(path, "probe-cookie-value-12345678901234567890\n")
    path
  end
end
