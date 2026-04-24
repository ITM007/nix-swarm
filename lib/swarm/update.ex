defmodule Swarm.Update do
  @moduledoc false

  alias Swarm.Deploy
  alias Swarm.Remote

  @default_attempts 40
  @default_retry_ms 1_500

  def run(opts, remote \\ nil) do
    opts = normalize_opts(opts)
    attempts = fetch_option(opts, :update_attempts, @default_attempts)
    retry_ms = fetch_option(opts, :update_retry_ms, @default_retry_ms)
    before = maybe_fetch_cluster_state(remote)
    deploy_opts = effective_deploy_opts(opts, before)
    expected_nodes = target_nodes(before, Keyword.get(deploy_opts, :hosts, []))
    deploy = Deploy.run(deploy_opts)

    post_update_state =
      if deploy.dry_run do
        before
      else
        wait_for_cluster_state(remote, version_map(before), expected_nodes, attempts, retry_ms)
      end

    %{
      deploy: deploy,
      target_hosts: Keyword.get(deploy_opts, :hosts, []),
      target_nodes: expected_nodes,
      before_versions: version_map(before),
      after_versions: version_map(post_update_state),
      version_changed?: versions_changed?(version_map(before), version_map(post_update_state)),
      completed_at:
        NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
    }
  end

  def versions_changed?(before_versions, after_versions) do
    common_nodes =
      before_versions
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(after_versions, &1))

    cond do
      common_nodes == [] ->
        after_versions != before_versions

      true ->
        Enum.any?(common_nodes, fn node ->
          Map.get(before_versions, node) != Map.get(after_versions, node)
        end) or Map.keys(before_versions) != Map.keys(after_versions)
    end
  end

  @doc false
  def effective_deploy_opts(opts, nil), do: normalize_opts(opts)

  def effective_deploy_opts(opts, cluster_state) do
    opts = normalize_opts(opts)

    if Keyword.has_key?(opts, :hosts) or Keyword.has_key?(opts, :host) do
      opts
    else
      case target_hosts(cluster_state) do
        [] -> opts
        hosts -> Keyword.put(opts, :hosts, hosts)
      end
    end
  end

  @doc false
  def target_hosts(nil), do: []

  def target_hosts(%{overview: %{members: %{live_nodes: live_nodes, deploy_hosts: deploy_hosts}}}) do
    live_nodes
    |> Enum.map(&Map.get(deploy_hosts, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def target_hosts(_cluster_state), do: []

  @doc false
  def target_nodes(nil, _target_hosts), do: []

  def target_nodes(%{overview: %{members: %{live_nodes: live_nodes}}}, []) do
    Enum.map(live_nodes, &Atom.to_string/1)
  end

  def target_nodes(%{overview: %{members: %{deploy_hosts: deploy_hosts}}}, target_hosts) do
    deploy_hosts
    |> Enum.reduce([], fn {node, host}, acc ->
      if host in target_hosts do
        [Atom.to_string(node) | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  def target_nodes(_cluster_state, _target_hosts), do: []

  @doc false
  def rollout_report_ready?(before_versions, after_versions, expected_nodes) do
    expected_nodes = Enum.uniq(expected_nodes)

    cond do
      after_versions == %{} ->
        false

      expected_nodes != [] and not Enum.all?(expected_nodes, &Map.has_key?(after_versions, &1)) ->
        false

      expected_nodes == [] ->
        true

      true ->
        changed_nodes =
          Enum.filter(expected_nodes, fn node ->
            Map.get(before_versions, node) != Map.get(after_versions, node)
          end)

        unchanged_nodes = expected_nodes -- changed_nodes
        changed_nodes == [] or unchanged_nodes == []
    end
  end

  defp maybe_fetch_cluster_state(nil), do: nil

  defp maybe_fetch_cluster_state(remote) do
    node = Remote.connect!(remote)
    overview = Remote.rpc!(node, Swarm.API, :cluster_overview, [])
    %{overview: overview, versions: extract_versions(overview)}
  end

  defp wait_for_cluster_state(nil, _before_versions, _expected_nodes, _attempts, _retry_ms),
    do: nil

  defp wait_for_cluster_state(remote, before_versions, expected_nodes, attempts, retry_ms) do
    Enum.reduce_while(1..attempts, nil, fn attempt, latest_state ->
      current_state =
        case try_fetch_cluster_state(remote) do
          {:ok, state} -> state
          {:error, _reason} -> latest_state
        end

      cond do
        current_state &&
            rollout_report_ready?(before_versions, current_state.versions, expected_nodes) ->
          {:halt, current_state}

        attempt == attempts and current_state ->
          {:halt, current_state}

        attempt == attempts ->
          raise RuntimeError,
                "cluster update finished but the cluster did not come back online in time"

        true ->
          Process.sleep(retry_ms)
          {:cont, current_state}
      end
    end)
  end

  defp try_fetch_cluster_state(remote) do
    {:ok, maybe_fetch_cluster_state(remote)}
  rescue
    error in [Remote.Error, RuntimeError, ArgumentError] ->
      {:error, Exception.message(error)}
  end

  defp extract_versions(%{status: %{nodes: nodes}}) do
    nodes
    |> Enum.map(fn {node, node_status} ->
      {Atom.to_string(node), Map.get(node_status, :version, "unknown")}
    end)
    |> Enum.into(%{})
  end

  defp version_map(nil), do: %{}
  defp version_map(%{versions: versions}), do: versions

  defp fetch_option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp fetch_option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Enum.to_list(opts)
end
