defmodule NixSwarm.Config do
  @moduledoc false

  alias NixSwarm.NodeName
  alias NixSwarm.Service

  @default_runtime %{
    connect_interval_ms: 500,
    reconcile_interval_ms: 500,
    command_timeout_ms: 5_000,
    executor: %{adapter: :fake, root: Path.join(System.tmp_dir!(), "nix-swarm")},
    generation: "dev"
  }

  def current do
    case :persistent_term.get({__MODULE__, :config}, nil) do
      nil ->
        config = load_current()
        :persistent_term.put({__MODULE__, :config}, config)
        config
      config ->
        config
    end
  end

  def invalidate_cache do
    :persistent_term.erase({__MODULE__, :config})
    :persistent_term.erase({__MODULE__, :peers})
  end

  defp load_current do
    raw =
      Application.get_env(:nix_swarm, :cluster_config) ||
        load_config_for_current() ||
        %{}

    normalize(raw)
  end

  defp load_config_for_current do
    path =
      Application.get_env(:nix_swarm, :config_path) || System.get_env("NIX_SWARM_CONFIG_PATH")

    case load_from_path(path) do
      {:ok, terms} -> terms
      {:error, _reason} -> nil
      nil -> nil
    end
  end

  def peers do
    current().peers
  end

  def runtime do
    current().runtime
  end

  def load_from_path(nil), do: nil

  def load_from_path(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, terms} ->
        {:ok, terms |> normalize_terms()}

      {:error, reason} ->
        {:error, "failed to read nix-swarm config at #{path}: #{inspect(reason)}"}
    end
  end

  def normalize(raw) do
    nodes = normalize_nodes(NixSwarm.fetch_value(raw, :nodes, %{}))
    peers = normalize_peers(NixSwarm.fetch_value(raw, :peers, Map.keys(nodes)))
    runtime = normalize_runtime(NixSwarm.fetch_value(raw, :runtime, %{}))

    %{
      peers: peers,
      nodes: nodes,
      services: normalize_services(NixSwarm.fetch_value(raw, :services, [])),
      runtime: runtime,
      ingress: normalize_ingress(NixSwarm.fetch_value(raw, :ingress, []))
    }
  end

  defp normalize_terms([single]) when is_list(single), do: Enum.into(single, %{})
  defp normalize_terms(terms) when is_list(terms), do: Enum.into(terms, %{})

  defp normalize_services(raw_services) do
    raw_services
    |> List.wrap()
    |> Enum.map(&Service.normalize/1)
  end

  defp normalize_peers(raw_peers) do
    raw_peers
    |> List.wrap()
    |> Enum.map(&normalize_node_name/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_nodes(raw_nodes) when raw_nodes in [%{}, []], do: %{}

  defp normalize_nodes(raw_nodes) do
    raw_nodes
    |> Enum.into(%{}, fn {node_name, attrs} ->
      labels =
        attrs
        |> NixSwarm.fetch_value(:labels, [])
        |> List.wrap()
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      deploy_host =
        attrs
        |> NixSwarm.fetch_value(:deploy_host, NixSwarm.fetch_value(attrs, :deployHost))
        |> normalize_optional_string()

      {normalize_node_name(node_name), %{labels: labels, deploy_host: deploy_host}}
    end)
  end

  defp normalize_runtime(raw_runtime) do
    executor = normalize_executor(NixSwarm.fetch_value(raw_runtime, :executor, %{}))

    @default_runtime
    |> Map.merge(%{
      connect_interval_ms:
        normalize_integer(
          NixSwarm.fetch_value(raw_runtime, :connect_interval_ms),
          @default_runtime.connect_interval_ms
        ),
      reconcile_interval_ms:
        normalize_integer(
          NixSwarm.fetch_value(raw_runtime, :reconcile_interval_ms),
          @default_runtime.reconcile_interval_ms
        ),
      command_timeout_ms:
        normalize_integer(
          NixSwarm.fetch_value(raw_runtime, :command_timeout_ms),
          @default_runtime.command_timeout_ms
        ),
      generation:
        to_string(NixSwarm.fetch_value(raw_runtime, :generation, @default_runtime.generation)),
      executor: executor
    })
  end

  defp normalize_executor(:systemd), do: %{adapter: :systemd}
  defp normalize_executor("systemd"), do: %{adapter: :systemd}

  defp normalize_executor(raw_executor) when is_map(raw_executor) or is_list(raw_executor) do
    adapter =
      case NixSwarm.fetch_value(raw_executor, :adapter, :fake) do
        value when value in [:systemd, "systemd"] -> :systemd
        _ -> :fake
      end

    case adapter do
      :systemd ->
        %{adapter: :systemd}

      :fake ->
        root =
          raw_executor
          |> NixSwarm.fetch_value(:root, @default_runtime.executor.root)
          |> to_string()

        %{adapter: :fake, root: root}
    end
  end

  defp normalize_executor(_), do: @default_runtime.executor

  defp normalize_integer(nil, default), do: default
  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp normalize_integer(_, default), do: default

  defp normalize_node_name(name) when is_atom(name), do: name
  defp normalize_node_name(name), do: NodeName.to_node!(name, label: "configured node name")

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp normalize_ingress(raw_sites) do
    %{
      sites:
        raw_sites
        |> List.wrap()
        |> Enum.reduce(%{}, fn site, acc ->
          name = NixSwarm.fetch_value(site, :name, "") |> to_string()

          next = %{
            domain: NixSwarm.fetch_value(site, :domain, name) |> to_string(),
            service: NixSwarm.fetch_value(site, :service, "") |> to_string(),
            ports:
              NixSwarm.fetch_value(site, :ports, [])
              |> List.wrap()
              |> Enum.map(&normalize_integer(&1, 0)),
            scheme: NixSwarm.fetch_value(site, :scheme, "http") |> to_string(),
            default: NixSwarm.fetch_value(site, :default, false) == true
          }

          if next.service != "" do
            Map.put(acc, name, next)
          else
            acc
          end
        end)
    }
  end
end
