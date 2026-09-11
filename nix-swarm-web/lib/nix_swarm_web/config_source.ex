defmodule NixSwarmWeb.ConfigSource do
  @moduledoc """
  Read-only projection of the operator's Nix configuration source.

  The web service never receives a source-tree path by default. When the
  operator explicitly configures `:nix_swarm_web, :config_source` (the
  `NIX_SWARM_CONFIG_SOURCE` environment variable), this module indexes the
  `*.nix` files under that directory and serves their contents with strict
  exclusions:

    * directories named `secrets` and hidden (dot-prefixed) entries are never
      scanned;
    * filenames that look like credential material (`cookie`, `secret`,
      `token`, passphrase, private keys) are never indexed;
    * reads are limited to files that appear in the scanned index, so path
      traversal and absolute paths are rejected;
    * each file read is capped at `max_bytes/0` and reports truncation.

  This is a display-only feature. Nothing here evaluates, deploys, or mutates
  configuration.
  """

  @max_files 300
  @max_depth 6
  @max_bytes 512 * 1024

  @cluster_basenames ~w(cluster.nix flake.nix configuration.nix config.nix)
  @ignored_dirs ~w(secrets)
  @credentialish ~r/(^|[_.-])(cookie|secret|secrets|credential|credentials|token|passphrase|password)($|[_.-])|\.(key|pem|crt)$/i

  @type file_entry :: %{rel: binary(), path: binary(), size: non_neg_integer()}
  @type group :: %{label: binary(), files: [file_entry()]}
  @type source :: %{
          enabled?: boolean(),
          root: binary() | nil,
          file_count: non_neg_integer(),
          groups: [group()]
        }

  @doc "The per-file content cap in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Loads the source index for the configured directory (or `path` when given).

  Returns a disabled source when nothing is configured or the path is not an
  existing directory, so callers can simply hide the config section.
  """
  @spec load(binary() | nil) :: source()
  def load(path \\ configured_path()) do
    case normalize_root(path) do
      {:ok, root} ->
        files = scan(root)
        %{enabled?: true, root: root, file_count: length(files), groups: group_files(files)}

      :error ->
        %{enabled?: false, root: nil, file_count: 0, groups: []}
    end
  end

  @doc """
  Reads one indexed file.

  `rel` must be a relative path that appears in the scanned index. Returns
  `{:ok, content, truncated?}` for indexed files and `{:error, :forbidden}`
  for anything outside the index.
  """
  @spec read(source(), binary()) :: {:ok, binary(), boolean()} | {:error, atom()}
  def read(%{groups: groups}, rel) when is_binary(rel) do
    case Map.fetch(index_by_rel(groups), rel) do
      {:ok, path} -> read_file(path)
      :error -> {:error, :forbidden}
    end
  end

  def read(_source, _rel), do: {:error, :forbidden}

  @doc """
  Resolves a map selection to a source-relative `.nix` path.

  * `"node"` — finds the machine file declaring `nodeName = "<key>"`.
  * `"service"` — exact `services/<key>.nix`, then a stem match (dropping
    `-web`/`-server`), then the first service file whose content mentions the
    service name.

  Returns `nil` when the source is disabled or nothing matches.
  """
  @spec resolve(source(), binary(), binary()) :: binary() | nil
  def resolve(%{enabled?: false}, _kind, _key), do: nil
  def resolve(source, "node", key) when is_binary(key), do: resolve_node(source, key)
  def resolve(source, "service", key) when is_binary(key), do: resolve_service(source, key)
  def resolve(_source, _kind, _key), do: nil

  @doc """
  Returns configured listening ports for the requested services.

  Runtime unit observations do not include application ports. This read-only
  lookup supplements them from indexed Nix declarations and reverse-proxy
  routes without evaluating the source.
  """
  @spec service_ports(source(), [binary()]) :: %{binary() => [pos_integer()]}
  def service_ports(%{enabled?: true, groups: groups}, names) when is_list(names) do
    files = Enum.flat_map(groups, & &1.files)

    names
    |> Enum.uniq()
    |> Map.new(fn name -> {name, ports_for_service(files, name)} end)
    |> Enum.reject(fn {_name, ports} -> ports == [] end)
    |> Map.new()
  end

  def service_ports(_source, _names), do: %{}

  defp resolve_node(%{groups: groups}, node_name) do
    files = files_for_group(groups, "Machines")
    pattern = ~r/nodeName\s*=\s*"#{Regex.escape(node_name)}"/

    Enum.find_value(files, fn file ->
      with {:ok, content, _} <- read_file(file.path),
           true <- Regex.match?(pattern, content) do
        file.rel
      else
        _ -> nil
      end
    end)
  end

  defp resolve_service(%{groups: groups}, service_name) do
    files = files_for_group(groups, "Services")
    candidates = ["#{service_name}.nix" | service_stem_basenames(service_name)]

    exact_or_stem =
      Enum.find_value(candidates, fn candidate ->
        Enum.find_value(files, fn file ->
          if Path.basename(file.rel) == candidate, do: file.rel
        end)
      end)

    exact_or_stem || content_match(files, service_name)
  end

  defp files_for_group(groups, label) do
    case Enum.find(groups, &(&1.label == label)) do
      nil -> []
      %{files: files} -> files
    end
  end

  defp service_stem_basenames(name) do
    [name, String.replace_suffix(name, "-web", ""), String.replace_suffix(name, "-server", "")]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "" or &1 == name))
    |> Enum.map(&"#{&1}.nix")
  end

  defp content_match(files, name) do
    escaped = Regex.escape(name)
    pattern = ~r/\b#{escaped}\.enable\b|\b#{escaped}\s*=\s*\{|systemd\.services\.#{escaped}\b/i

    Enum.find_value(files, fn file ->
      with {:ok, content, _} <- read_file(file.path),
           true <- Regex.match?(pattern, content) do
        file.rel
      else
        _ -> nil
      end
    end)
  end

  defp ports_for_service(files, name) do
    aliases = service_aliases(name)

    files
    |> Enum.flat_map(fn file ->
      case read_file(file.path) do
        {:ok, content, _truncated?} -> ports_from_content(content, aliases, name)
        _ -> []
      end
    end)
    |> Enum.filter(&(&1 in 1..65_535))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp service_aliases(name) do
    [
      name,
      String.replace_suffix(name, "-web", ""),
      String.replace_suffix(name, "-server", ""),
      String.replace_suffix(name, "-editor", ""),
      String.replace_suffix(name, "home", "")
    ]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
  end

  defp ports_from_content(content, aliases, service_name) do
    alias_pattern = aliases |> Enum.map(&Regex.escape/1) |> Enum.join("|")

    direct_ports =
      Regex.scan(
        ~r/\b(?:services\.)?(?:#{alias_pattern})(?:\.[a-zA-Z0-9_-]+)*\.(?:port|http_port|HTTP_PORT|SERVER_PORT|listen_port|peerPort|PORT|ldap_port)\s*=\s*"?(\d+)"?/,
        content,
        capture: :all_but_first
      )
      |> Enum.map(fn [port] -> String.to_integer(port) end)

    scoped_ports =
      Regex.scan(
        ~r/(?ms)\b(?:systemd\.)?services?\.(?:#{alias_pattern})\s*=\s*\{(.*?)(?:\n\s*\};|\n\};)/,
        content,
        capture: :all_but_first
      )
      |> Enum.flat_map(&ports_from_scoped_text/1)

    nested_ports =
      Regex.scan(
        ~r/(?ms)\b(?:#{alias_pattern})\s*=\s*\{(.*?)(?:\n\s*\};|\n\};)/,
        content,
        capture: :all_but_first
      )
      |> Enum.flat_map(&ports_from_scoped_text/1)

    route_ports =
      Regex.scan(
        ~r{(?ms)^\s*([a-z0-9-]+)\.home(?::(\d+))?\s*\{.*?^\s*reverse_proxy\s+(?:https?://)?(?:127\.0\.0\.1|localhost):(\d+)},
        content,
        capture: :all_but_first
      )
      |> Enum.flat_map(fn [host, _listener, upstream] ->
        if host in aliases, do: [String.to_integer(upstream)], else: []
      end)

    caddy_ports =
      if service_name == "caddy" and Regex.match?(~r/\bcaddy\s*=\s*\{/, content) do
        [80, 443]
      else
        []
      end

    direct_ports ++ scoped_ports ++ nested_ports ++ route_ports ++ caddy_ports
  end

  defp ports_from_scoped_text([text]), do: port_assignments(text)

  defp port_assignments(text) do
    Regex.scan(
      ~r/\b(?:port|http_port|HTTP_PORT|SERVER_PORT|listen_port|peerPort|PORT|ldap_port)\s*=\s*"?(\d+)"?/,
      text,
      capture: :all_but_first
    )
    |> Enum.map(fn [port] -> String.to_integer(port) end)
  end

  defp configured_path do
    case Application.get_env(:nix_swarm_web, :config_source) do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> nil
    end
  end

  defp normalize_root(nil), do: :error

  defp normalize_root(path) when is_binary(path) do
    root = Path.expand(path)

    case File.stat(root) do
      {:ok, %{type: :directory}} -> {:ok, root}
      _ -> :error
    end
  end

  defp scan(root), do: do_scan(root, "", 0, [])

  defp do_scan(_directory, _rel, depth, acc) when depth > @max_depth, do: acc

  defp do_scan(directory, rel, depth, acc) do
    directory
    |> File.ls()
    |> case do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce(acc, fn name, result ->
          candidate = Path.join(directory, name)
          candidate_rel = join_rel(rel, name)

          cond do
            length(result) >= @max_files -> result
            File.dir?(candidate) -> maybe_scan_dir(candidate, candidate_rel, depth, result)
            indexable_file?(name) -> add_file(candidate, candidate_rel, result)
            true -> result
          end
        end)

      {:error, _reason} ->
        acc
    end
  end

  defp maybe_scan_dir(directory, rel, depth, acc) do
    if ignored_dir?(rel) do
      acc
    else
      do_scan(directory, rel, depth + 1, acc)
    end
  end

  defp ignored_dir?(rel) do
    segments = String.split(rel, "/", trim: true)

    Enum.any?(segments, fn segment ->
      String.starts_with?(segment, ".") or segment in @ignored_dirs
    end)
  end

  defp indexable_file?(name) do
    String.ends_with?(name, ".nix") and
      not String.starts_with?(name, ".") and
      Regex.match?(@credentialish, name) == false
  end

  defp add_file(path, rel, acc) do
    size =
      case File.stat(path) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end

    [%{rel: rel, path: path, size: size} | acc]
  end

  defp join_rel("", name), do: name
  defp join_rel(rel, name), do: rel <> "/" <> name

  defp group_files(files) do
    files
    |> Enum.group_by(&group_label(&1.rel))
    |> Enum.map(fn {label, entries} ->
      %{label: label, files: Enum.sort_by(entries, & &1.rel)}
    end)
    |> Enum.sort_by(&group_priority(&1.label))
  end

  defp group_label(rel) do
    case String.split(rel, "/", trim: true) do
      [basename] -> if basename in @cluster_basenames, do: "Cluster", else: "Root"
      [directory | _rest] -> directory_label(directory)
    end
  end

  defp group_priority(label) do
    case Enum.find_index(~w(Cluster Machines Services NixOS Packages Hosts Root), &(&1 == label)) do
      nil -> 100
      index -> index
    end
  end

  defp directory_label("nixos"), do: "NixOS"
  defp directory_label("packages"), do: "Packages"
  defp directory_label(word), do: String.capitalize(word, :ascii)

  defp index_by_rel(groups) do
    Map.new(Enum.flat_map(groups, & &1.files), fn entry -> {entry.rel, entry.path} end)
  end

  defp read_file(path) do
    with {:ok, %{size: size}} <- File.stat(path) do
      if size > @max_bytes do
        with {:ok, file} <- File.open(path, [:read, :binary]) do
          content = IO.binread(file, @max_bytes)
          File.close(file)
          {:ok, content, true}
        end
      else
        case File.read(path) do
          {:ok, content} -> {:ok, content, false}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end
end
