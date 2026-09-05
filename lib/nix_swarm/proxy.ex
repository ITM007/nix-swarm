defmodule NixSwarm.Proxy do
  @moduledoc false

  # Facade for the optional built-in edge proxy (`NIX_SWARM_ROLE=proxy`).
  # Loads and validates the rendered (secret-free) config exactly once at
  # supervision boot and publishes it on :persistent_term for request-time
  # readers. Secrets never live in the config: they are read from
  # `$CREDENTIALS_DIRECTORY` by the auth layers that need them.

  alias NixSwarm.Proxy.Config

  @config_key {__MODULE__, :config}

  def config, do: :persistent_term.get(@config_key, nil)

  def load_config! do
    path =
      Application.get_env(:nix_swarm, :proxy_config_path) ||
        System.get_env("NIX_SWARM_PROXY_CONFIG_PATH")

    config =
      case Config.load_from_path(path) do
        {:ok, config} ->
          config

        {:error, message} ->
          raise "proxy config: #{message}"

        nil ->
          raise "proxy config: NIX_SWARM_PROXY_CONFIG_PATH is not set"
      end

    case Config.validate(config) do
      :ok ->
        :persistent_term.put(@config_key, config)
        config

      {:error, message} ->
        raise "proxy config invalid: #{message}"
    end
  end
end
