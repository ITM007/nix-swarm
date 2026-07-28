defmodule NixSwarm.Remote do
  @moduledoc false

  alias NixSwarm.QueryProtocol

  @query_timeout_ms 15_000
  @allowed_calls [
    {NixSwarm.API, :cluster_overview, 0},
    {NixSwarm.API, :cluster_members, 0},
    {NixSwarm.API, :operator_snapshot, 3},
    {NixSwarm.API, :logs, 2},
    {NixSwarm.API, :node_service_logs, 2},
    {NixSwarm.API, :cluster_logs, 2}
  ]
  @reported_capabilities @allowed_calls ++ [{NixSwarm.API, :local_cluster_logs, 1}]

  defmodule Error do
    defexception [:message]
  end

  def options!(opts) when is_list(opts) do
    target =
      case Keyword.fetch(opts, :target) do
        {:ok, value} when is_binary(value) and value != "" -> value
        {:ok, _value} -> fail("--target must not be blank")
        :error -> fail("missing required --target for remote command")
      end

    if Keyword.has_key?(opts, :cookie) or Keyword.has_key?(opts, :cookie_file) do
      fail(
        "operator cookie options were removed; read-only access now uses SSH and the local query socket"
      )
    end

    %{
      target: validate_target!(target),
      ssh_host: validate_ssh_host!(Keyword.get(opts, :ssh_host) || target_host(target)),
      query_fun: Keyword.get(opts, :query_fun)
    }
  end

  def connect!(opts) when is_list(opts), do: opts |> options!() |> connect!()

  def connect!(remote) when is_map(remote) do
    diagnostic = diagnose_connection(remote)

    if connected?(diagnostic) do
      remote
    else
      fail(format_connection_error(diagnostic))
    end
  end

  def connected?(%{connect_result: result}), do: result == true

  def diagnose_connection(remote, opts \\ []) when is_map(remote) and is_list(opts) do
    query_fun = Keyword.get(opts, :query_fun) || Map.get(remote, :query_fun) || (&query/2)

    case query_fun.(remote, :cluster_members) do
      {:ok, members} ->
        Map.merge(remote, %{
          target_node: remote,
          connect_result: true,
          remote_probe: %{cluster_members: %{status: :ok, value: members}}
        })

      {:error, reason} ->
        Map.merge(remote, %{
          target_node: remote,
          connect_result: false,
          remote_probe: %{cluster_members: %{status: :error, detail: inspect(reason)}}
        })
    end
  end

  def rpc!(remote, module, function, args) when is_map(remote) and is_list(args) do
    request = request_for!(module, function, args)
    query_fun = Map.get(remote, :query_fun) || (&query/2)

    case query_fun.(remote, request) do
      {:ok, value} ->
        value

      {:error, reason} ->
        fail("read-only query #{function}/#{length(args)} failed: #{inspect(reason)}")
    end
  end

  @doc false
  def rpc!(remote, module, function, args, query_fun) when is_function(query_fun, 2) do
    request = request_for!(module, function, args)

    case query_fun.(remote, request) do
      {:ok, value} ->
        value

      {:error, reason} ->
        fail("read-only query #{function}/#{length(args)} failed: #{inspect(reason)}")
    end
  end

  @doc false
  def function_exported?(_remote, module, function, arity) do
    {normalize_module(module), function, arity} in @reported_capabilities
  end

  @doc false
  def function_exported?(_remote, module, function, arity, _query_fun) do
    function_exported?(nil, module, function, arity)
  end

  def query(%{query_fun: query_fun} = remote, request) when is_function(query_fun, 2) do
    query_fun.(remote, request)
  end

  def query(remote, request) do
    with {:ok, payload} <- QueryProtocol.encode_request(request) do
      encoded = Base.url_encode64(payload, padding: false)
      run_ssh_query(remote, encoded)
    end
  end

  def doctor_context_rows(diagnostic) do
    [
      ["cluster target", diagnostic.target],
      ["SSH host", diagnostic.ssh_host],
      ["transport", "SSH to a local, read-only Unix socket"]
    ]
  end

  def diagnostic_checks(%{connect_result: true}) do
    [
      %{
        label: "restricted operator query",
        status: :ok,
        detail: "SSH and the local query socket responded"
      }
    ]
  end

  def diagnostic_checks(diagnostic) do
    [
      %{
        label: "restricted operator query",
        status: :error,
        detail: diagnostic.remote_probe.cluster_members.detail
      }
    ]
  end

  def connection_solutions(%{connect_result: true}) do
    ["The target is ready for read-only status, metrics, and bounded log queries."]
  end

  def connection_solutions(diagnostic) do
    [
      "Verify SSH access to #{diagnostic.ssh_host} with BatchMode enabled.",
      "Install the Nix-Swarm cluster package on the target so `nix-swarm-query` is available.",
      "Add the SSH user to the target's Nix-Swarm operator group, then start nix-swarmd."
    ]
  end

  def format_connection_error(diagnostic) do
    """
    unable to query #{diagnostic.target} through #{diagnostic.ssh_host}

    checks:
    #{Enum.map_join(diagnostic_checks(diagnostic), "\n", &format_check_line/1)}

    likely fixes:
    #{Enum.map_join(connection_solutions(diagnostic), "\n", &"  - #{&1}")}
    """
    |> String.trim()
  end

  def format_doctor_report(diagnostic) do
    heading = "doctor for #{diagnostic.target}"

    """
    #{heading}
    #{String.duplicate("=", String.length(heading))}
    connection context:
    #{Enum.map_join(doctor_context_rows(diagnostic), "\n", fn [label, value] -> "  #{label}: #{value}" end)}

    checks:
    #{Enum.map_join(diagnostic_checks(diagnostic), "\n", &format_check_line/1)}

    result:
      #{doctor_result(diagnostic)}

    fixes and next steps:
    #{Enum.map_join(connection_solutions(diagnostic), "\n", &"  - #{&1}")}
    """
    |> String.trim()
  end

  def doctor_result(%{connect_result: true}) do
    "The target is reachable and the restricted Nix-Swarm query API responded."
  end

  def doctor_result(_diagnostic) do
    "Issues were detected. Fix the failed check above, then retry."
  end

  defp request_for!(module, function, args) do
    key = {normalize_module(module), function, length(args)}

    case {key, args} do
      {{NixSwarm.API, :cluster_overview, 0}, []} ->
        :cluster_overview

      {{NixSwarm.API, :cluster_members, 0}, []} ->
        :cluster_members

      {{NixSwarm.API, :operator_snapshot, 3}, [service, node, lines]} ->
        {:operator_snapshot, service, node, lines}

      {{NixSwarm.API, :logs, 2}, [service, lines]} ->
        {:logs, to_string(service), lines}

      {{NixSwarm.API, :node_service_logs, 2}, [node, lines]} ->
        {:node_service_logs, node, lines}

      {{NixSwarm.API, :cluster_logs, 2}, [node, lines]} ->
        {:cluster_logs, node, lines}

      _ ->
        fail(
          "remote call #{inspect(module)}.#{function}/#{length(args)} is not read-only or allowlisted"
        )
    end
  end

  defp normalize_module(Swarm.API), do: NixSwarm.API
  defp normalize_module(module), do: module

  defp run_ssh_query(remote, encoded) do
    args = [
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=10",
      "-o",
      "ServerAliveInterval=5",
      "-o",
      "ServerAliveCountMax=2",
      "-o",
      "StrictHostKeyChecking=yes",
      "-o",
      "ClearAllForwardings=yes",
      "-o",
      "ForwardAgent=no",
      "-o",
      "ForwardX11=no",
      "-o",
      "PermitLocalCommand=no",
      "--",
      remote.ssh_host,
      "nix-swarm-query",
      encoded
    ]

    task = Task.async(fn -> System.cmd("ssh", args, stderr_to_stdout: true) end)

    case Task.yield(task, @query_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> decode_ssh_response(output)
      {:ok, {output, status}} -> {:error, {:ssh_failed, status, String.trim(output)}}
      nil -> {:error, :ssh_timeout}
    end
  rescue
    error -> {:error, {:ssh_failed, Exception.message(error)}}
  end

  defp decode_ssh_response(output) do
    with {:ok, response} <- QueryProtocol.decode_response(output) do
      response
    end
  end

  defp target_host(target) do
    case String.split(target, "@", parts: 2) do
      [_node, host] when host != "" -> host
      [host] -> host
    end
  end

  defp validate_target!(target) do
    if byte_size(target) <= 255 and
         String.match?(target, ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*(?:@[A-Za-z0-9][A-Za-z0-9_.-]*)?\z/) do
      target
    else
      fail("--target contains unsupported characters")
    end
  end

  defp validate_ssh_host!(host) do
    if byte_size(host) <= 255 and
         String.match?(host, ~r/\A[A-Za-z0-9][A-Za-z0-9_.@:-]*\z/) do
      host
    else
      fail("--ssh-host contains unsupported characters")
    end
  end

  defp format_check_line(%{label: label, status: status, detail: detail}) do
    status = if status == :ok, do: "ok", else: "fail"
    "  [#{status}] #{label}: #{detail}"
  end

  defp fail(message), do: raise(Error, message: message)
end
