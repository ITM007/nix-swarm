defmodule NixSwarmSecurityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias NixSwarm.QueryProtocol

  test "query protocol accepts only bounded read operations" do
    assert {:ok, "cluster-overview"} = QueryProtocol.encode_request(:cluster_overview)

    assert {:ok, encoded} =
             QueryProtocol.encode_request({:operator_snapshot, "api", :"node-a@test", 100})

    assert {:ok, {:operator_snapshot, "api", "node-a@test", 100}} =
             QueryProtocol.decode_request(encoded)

    assert {:ok, encoded_empty} =
             QueryProtocol.encode_request({:operator_snapshot, nil, nil, 25})

    assert {:ok, {:operator_snapshot, nil, nil, 25}} =
             QueryProtocol.decode_request(encoded_empty)

    assert {:error, :invalid_lines} =
             QueryProtocol.encode_request({:operator_snapshot, nil, nil, 0})

    assert {:ok, encoded} = QueryProtocol.encode_request({:logs, "api", 100})
    assert {:ok, {:logs, "api", 100}} = QueryProtocol.decode_request(encoded)

    assert {:error, :invalid_request} = QueryProtocol.encode_request({:logs, "api", 0})
    assert {:error, :invalid_request} = QueryProtocol.encode_request({:logs, "api", 1001})
    assert {:error, :invalid_request} = QueryProtocol.encode_request(:reconcile)
    assert {:error, :unsupported_request} = QueryProtocol.decode_request("reconcile")
    assert {:error, :invalid_response} = QueryProtocol.decode_response("not-base64!")

    response = {:ok, %{live_nodes: [:"new-node@release-test"]}}

    assert {:ok, ^response} =
             response
             |> QueryProtocol.encode_response()
             |> elem(1)
             |> QueryProtocol.decode_response()

    for operation <- [:node_service_logs, :cluster_logs] do
      assert {:ok, node_request} =
               QueryProtocol.encode_request({operation, :"node-a@test", 10})

      assert {:ok, {^operation, "node-a@test", 10}} =
               QueryProtocol.decode_request(node_request)
    end

    oversized = String.duplicate("x", QueryProtocol.max_request_bytes() + 1)
    assert {:error, :request_too_large} = QueryProtocol.decode_request(oversized)
  end

  test "local query socket returns membership without exposing arbitrary MFA" do
    socket_path = :sys.get_state(NixSwarm.QueryServer).path

    assert {:ok, {:ok, members}} =
             NixSwarm.QueryClient.query(:cluster_members, socket_path: socket_path)

    assert is_list(members.live_nodes)

    assert {:error, :invalid_request} =
             NixSwarm.QueryClient.query({:reconcile, []}, socket_path: socket_path)
  end

  test "installed query helper round-trips only a valid protocol request" do
    request = Base.url_encode64("cluster-members", padding: false)

    encoded_response =
      capture_io(fn ->
        NixSwarm.QueryCLI.main([request])
      end)

    assert {:ok, {:ok, members}} = QueryProtocol.decode_response(encoded_response)
    assert is_list(members.live_nodes)

    invalid_response =
      capture_io(fn ->
        NixSwarm.QueryCLI.main([Base.url_encode64("reconcile", padding: false)])
      end)

    assert {:ok, {:error, :unsupported_request}} =
             QueryProtocol.decode_response(invalid_response)
  end

  test "terminal output strips ANSI, OSC, and control characters" do
    hostile = "ok\e[31mred\e[0m\e]2;owned\a\0done\n"
    assert NixSwarm.ClusterLogs.terminal_safe(hostile) == "okreddone\n"
    refute NixSwarm.ClusterLogs.sanitize(hostile) =~ "\e"
  end

  test "generated cookie is strong and private" do
    root = Path.join(System.tmp_dir!(), "nix-swarm-cookie-#{System.unique_integer([:positive])}")
    path = Path.join(root, "secrets/cluster.cookie")
    on_exit(fn -> File.rm_rf!(root) end)

    cookie = NixSwarm.Credentials.ensure_local_cookie!(path)

    assert byte_size(cookie) in 32..64
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
    assert NixSwarm.Credentials.ensure_local_cookie!(path) == cookie

    File.write!(path, "too-short\n")

    assert_raise ArgumentError, ~r/must contain 32-64 safe characters/, fn ->
      NixSwarm.Credentials.ensure_local_cookie!(path)
    end
  end

  test "credential generation rejects a symlink cookie path" do
    root = Path.join(System.tmp_dir!(), "nix-swarm-link-#{System.unique_integer([:positive])}")
    directory = Path.join(root, "secrets")
    target = Path.join(root, "unrelated")
    cookie_path = Path.join(directory, "cluster.cookie")
    File.mkdir_p!(directory)
    File.write!(target, String.duplicate("x", 40))
    File.ln_s!(target, cookie_path)
    on_exit(fn -> File.rm_rf!(root) end)

    assert_raise ArgumentError, ~r/must be a regular file/, fn ->
      NixSwarm.Credentials.ensure_local_cookie!(cookie_path)
    end
  end
end
