defmodule NixSwarm.Config.Server do
  @moduledoc """
  Owns the immutable runtime configuration snapshot used by agent processes.

  Readers use a protected ETS table, so reconciliation does not serialize on a
  GenServer call. Reloads validate a complete replacement before publishing it.
  """

  use GenServer

  alias NixSwarm.Config

  @table :nix_swarm_config_snapshot

  def table, do: @table

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  def metadata do
    case :ets.lookup(@table, :metadata) do
      [{:metadata, metadata}] -> metadata
      [] -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :protected,
      read_concurrency: true,
      write_concurrency: true
    ])

    case load_and_publish() do
      {:ok, metadata} -> {:ok, metadata}
      {:error, reason} -> {:stop, {:invalid_config, reason}}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case load_and_publish() do
      {:ok, metadata} -> {:reply, {:ok, metadata}, metadata}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp load_and_publish do
    with {:ok, config} <- configured_snapshot(),
         :ok <- Config.validate(config) do
      digest = Config.digest_for(config)

      metadata = %{
        digest: digest,
        generation: config.runtime.generation,
        loaded_at: System.system_time(:second)
      }

      true = :ets.insert(@table, [{:config, config}, {:digest, digest}, {:metadata, metadata}])
      {:ok, metadata}
    end
  end

  defp configured_snapshot do
    case Application.get_env(:nix_swarm, :cluster_config) do
      nil -> Config.load_current()
      raw -> {:ok, Config.normalize(raw)}
    end
  rescue
    error in [ArgumentError, RuntimeError] -> {:error, Exception.message(error)}
  end
end
