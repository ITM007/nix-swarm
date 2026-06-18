defmodule NixSwarm do
  @moduledoc """
  Leaderless Nix-defined service orchestration for small NixOS clusters.
  """

  @operator_command "swarm"

  @rpc_timeout_ms 5_000

  version_path = Path.join(__DIR__, "../../VERSION")

  @fallback_version (case File.read(version_path) do
                       {:ok, content} -> String.trim(content)
                       {:error, _} -> "0.0.0-dev"
                     end)

  def config do
    NixSwarm.Config.current()
  end

  def app_version do
    case Application.spec(:nix_swarm, :vsn) do
      nil -> @fallback_version
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn -> to_string(vsn)
    end
  end

  def release_label do
    "v#{app_version()}"
  end

  def operator_command do
    @operator_command
  end

  def operator_launch(target \\ "NODE") do
    "#{operator_command()} --target #{target}"
  end

  @doc "Default timeout in milliseconds for distributed Erlang :rpc.call operations."
  def rpc_timeout_ms, do: @rpc_timeout_ms

  @doc """
  Escapes a string for use as a Nix string literal (double-quoted).
  Handles backslash, double-quote, and dollar-brace interpolation.
  """
  def nix_string_literal(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("${", "\\${")

    "\"#{escaped}\""
  end

  @doc """
  Fetch a key from a map (trying both atom and string forms) or keyword list.
  Returns `default` when the key is missing.
  """
  def fetch_value(data, key, default \\ nil)

  def fetch_value(data, key, default) when is_map(data),
    do: Map.get(data, key, Map.get(data, to_string(key), default))

  def fetch_value(data, key, default) when is_list(data),
    do: Keyword.get(data, key, default)
end
