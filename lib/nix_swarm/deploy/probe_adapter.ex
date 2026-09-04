defmodule NixSwarm.Deploy.ProbeAdapter do
  @moduledoc """
  Production SSH probe adapter for `NixSwarm.Deploy.Preflight`.

  Every probe runs through an injected `command_fun/2` so tests stay offline;
  the default command fun executes `ssh` with the same bounded options as the
  rest of the deployment tooling. Probe results are normalized maps/atoms that
  `Preflight` can classify and redact: credential digests are compared only as
  hashes, never returned.
  """

  alias NixSwarm.QueryProtocol

  @default_timeout_ms 15_000
  @min_free_kib 4 * 1024 * 1024
  @ssh_options [
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=10",
    "-o",
    "ServerAliveInterval=10",
    "-o",
    "ServerAliveCountMax=3",
    "-o",
    "StrictHostKeyChecking=yes",
    "-o",
    "ClearAllForwardings=yes",
    "-o",
    "ForwardAgent=no"
  ]

  @spec probe(
          NixSwarm.Deploy.Target.t() | map(),
          timeout(),
          keyword() | (String.t(), [String.t()] -> {String.t(), non_neg_integer()})
        ) :: map()
  def probe(target), do: probe(target, @default_timeout_ms, [])

  def probe(target, timeout_ms), do: probe(target, timeout_ms, [])

  def probe(target, timeout_ms, command_fun) when is_function(command_fun, 2) do
    probe(target, timeout_ms, command_fun: command_fun)
  end

  def probe(target, timeout_ms, opts) when is_list(opts) do
    command_fun = Keyword.get(opts, :command_fun, &run_command/2)
    host = to_string(Map.fetch!(target, :host))
    secret_file = Keyword.get(opts, :secret_file)

    %{
      ssh: ssh_probe(command_fun, host),
      nixos: nixos_probe(command_fun, host),
      privilege: privilege_probe(command_fun, host),
      architecture: architecture_probe(command_fun, host),
      disk: disk_probe(command_fun, host),
      credential: credential_probe(command_fun, host, secret_file),
      service: service_probe(command_fun, host),
      query: query_probe(command_fun, host, timeout_ms),
      protocol: protocol_probe(command_fun, host, timeout_ms)
    }
  end

  def probe(target, timeout_ms, command_fun, opts)
      when is_function(command_fun, 2) and is_list(opts) do
    probe(target, timeout_ms, Keyword.put(opts, :command_fun, command_fun))
  end

  @doc "Returns the local build host architecture used as the probe expectation."
  def local_architecture do
    {output, _status} = System.cmd("uname", ["-m"])
    output |> String.trim() |> String.downcase()
  end

  defp ssh_probe(command_fun, host) do
    case command_fun.("ssh", @ssh_options ++ ["--", host, "true"]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, ssh_error(output, status)}
    end
  end

  defp nixos_probe(command_fun, host) do
    case command_fun.("ssh", @ssh_options ++ ["--", host, "nixos-version"]) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  defp privilege_probe(command_fun, host) do
    command = "if [ \"$(id -u)\" -ne 0 ]; then sudo -n true; fi"

    case command_fun.("ssh", @ssh_options ++ ["--", host, command]) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  defp architecture_probe(command_fun, host) do
    expected = local_architecture()

    case command_fun.("ssh", @ssh_options ++ ["--", host, "uname -m"]) do
      {output, 0} ->
        %{ok: String.trim(output) == expected, remote: String.trim(output), expected: expected}

      {output, _status} ->
        %{ok: false, remote: String.trim(output), expected: expected}
    end
  end

  defp disk_probe(command_fun, host) do
    command = "df -Pk /nix | awk 'NR == 2 {print $4}'"

    case command_fun.("ssh", @ssh_options ++ ["--", host, command]) do
      {output, 0} ->
        free_kib = output |> String.trim() |> parse_integer()
        %{ok: free_kib >= @min_free_kib, free_kib: free_kib}

      {output, _status} ->
        %{ok: false, free_kib: 0, error: String.trim(output)}
    end
  end

  defp credential_probe(command_fun, host, secret_file) do
    command =
      "if test -f /etc/nixos/nix-swarm/secrets/nix-swarm.cookie; then " <>
        "tr -d '\\r\\n' < /etc/nixos/nix-swarm/secrets/nix-swarm.cookie | sha256sum; " <>
        "else printf '%s\\n' '__NIX_SWARM_MISSING__'; fi"

    case command_fun.("ssh", @ssh_options ++ ["--", host, command]) do
      {output, status} when status != 0 ->
        {:error, "credential probe failed on #{host} (#{status}): #{String.trim(output)}"}

      {output, 0} ->
        case String.trim(output) do
          "__NIX_SWARM_MISSING__" ->
            # A fresh host has no remote credential. Enrollment creates the
            # local secret (if needed) and installs it before activation.
            :missing

          remote_digest ->
            case {parse_digest(remote_digest), require_local_cookie(secret_file)} do
              {{:ok, digest}, :ok} ->
                if digest == cookie_digest(secret_file), do: :present, else: :mismatched

              _ ->
                # Local secret missing/unreadable or an invalid remote
                # fingerprint: fail closed as mismatched because the shared
                # credential cannot be confirmed.
                %{ok: true, state: :mismatched}
            end
        end
    end
  end

  defp parse_digest(output) do
    case Regex.run(~r/\A([a-fA-F0-9]{64})\b/, output, capture: :all_but_first) do
      [digest] -> {:ok, String.downcase(digest)}
      _ -> {:error, "remote credential fingerprint was not a sha256 digest"}
    end
  end

  defp service_probe(command_fun, host) do
    command =
      "systemctl is-active --quiet nix-swarmd.service; rc=$?; " <>
        "if [ \"$rc\" -eq 0 ]; then printf 'running'; " <>
        "elif systemctl list-unit-files nix-swarmd.service --no-legend >/dev/null 2>&1; " <>
        "then printf 'inactive'; else printf 'missing'; fi"

    case command_fun.("ssh", @ssh_options ++ ["--", host, command]) do
      {output, 0} -> probe_state(output)
      {_output, _status} -> :unqueryable
    end
  end

  defp query_probe(command_fun, host, _timeout_ms) do
    encoded = encode_request(:cluster_members)

    command =
      "if command -v nix-swarm-query >/dev/null 2>&1; then nix-swarm-query #{encoded}; " <>
        "else printf '%s' '__NIX_SWARM_QUERY_MISSING__'; fi"

    case command_fun.("ssh", @ssh_options ++ ["--", host, command]) do
      {output, 0} ->
        case String.trim(output) do
          "__NIX_SWARM_QUERY_MISSING__" -> %{ok: true, state: :missing}
          output -> decode_query_response(output)
        end

      {_output, _status} ->
        %{ok: true, state: :unqueryable}
    end
  end

  defp protocol_probe(command_fun, host, _timeout_ms) do
    encoded = encode_request(:capabilities)

    command =
      "if command -v nix-swarm-query >/dev/null 2>&1; then nix-swarm-query #{encoded}; " <>
        "else printf '%s' '__NIX_SWARM_QUERY_MISSING__'; fi"

    case command_fun.("ssh", @ssh_options ++ ["--", host, command]) do
      {output, 0} ->
        case String.trim(output) do
          "__NIX_SWARM_QUERY_MISSING__" ->
            %{ok: true, state: :unknown}

          output ->
            with {:ok, %{capabilities: capabilities}} <- QueryProtocol.decode_response(output),
                 %{protocol_version: version} when is_integer(version) <- capabilities do
              if version == QueryProtocol.protocol_version(),
                do: %{ok: true, state: :compatible},
                else: %{ok: true, state: :incompatible}
            else
              _ -> %{ok: true, state: :unknown}
            end
        end

      {_output, _status} ->
        %{ok: true, state: :unknown}
    end
  end

  defp decode_query_response(output) do
    case QueryProtocol.decode_response(output) do
      {:ok, %{} = response} ->
        %{ok: true, state: :active, response_summary: query_summary(response)}

      _ ->
        %{ok: true, state: :unqueryable}
    end
  end

  defp query_summary(response) do
    %{
      queried_node: Map.get(response, :queried_node),
      live_nodes: Map.get(response, :live_nodes, [])
    }
  end

  defp encode_request(request) do
    {:ok, payload} = QueryProtocol.encode_request(request)
    Base.url_encode64(payload, padding: false)
  end

  defp probe_state(output) do
    case output |> String.trim() do
      "running" -> :running
      "inactive" -> :inactive
      "missing" -> :missing
      _ -> :unqueryable
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> 0
    end
  end

  defp require_local_cookie(nil), do: {:error, "no local credential file is configured"}

  defp require_local_cookie(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _other} -> {:error, "credential path must be a regular file: #{path}"}
      {:error, :enoent} -> {:error, "local credential file does not exist: #{path}"}
      {:error, reason} -> {:error, "cannot inspect #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp cookie_digest(path) do
    path
    |> File.read!()
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp ssh_error(output, status) do
    message =
      output |> String.trim() |> String.split("\n") |> List.last() || "SSH connection failed"

    "#{message} (exit #{status})"
  end

  defp run_command(executable, args), do: System.cmd(executable, args, stderr_to_stdout: true)
end
