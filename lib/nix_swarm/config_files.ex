defmodule NixSwarm.ConfigFiles do
  @moduledoc false

  @default_cookie_file "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie"
  @local_cookie_filenames ["nix-swarm.cookie", "swarm.cookie"]
  @safe_generated_name_regex ~r/^[A-Za-z0-9][A-Za-z0-9_.@-]*$/

  def defaults(source \\ nil) do
    source = Path.expand(source || NixSwarm.Paths.default_source())

    normalize_paths(%{
      source: source,
      cluster_file: default_cluster_file(source),
      machines_dir: default_machines_dir(source),
      services_dir: default_services_dir(source)
    })
  end

  defp default_cluster_file(source) do
    [
      Path.join(source, "cluster.nix"),
      Path.join(source, "cluster/cluster.nix"),
      Path.join(source, "examples/config/cluster/cluster.nix")
    ]
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> Path.join(source, "cluster.nix")
      path -> path
    end
  end

  defp default_machines_dir(source) do
    [Path.join(source, "machines"), Path.join(source, "examples/config/machines")]
    |> Enum.find(&File.dir?/1)
    |> case do
      nil -> Path.join(source, "machines")
      path -> path
    end
  end

  defp default_services_dir(source) do
    flat = Path.join(source, "services")
    legacy = Path.join(source, "cluster/services")
    if File.dir?(flat), do: flat, else: legacy
  end

  def normalize_paths(paths) when is_map(paths) do
    source = expand_path(Map.get(paths, :source, "."))
    default_cluster_file = default_cluster_file(source)
    default_machines_dir = default_machines_dir(source)

    default_services_dir =
      if File.dir?(Path.join(source, "services")) do
        Path.join(source, "services")
      else
        Path.join(source, "cluster/services")
      end

    %{
      source: source,
      cluster_file: expand_path(Map.get(paths, :cluster_file, default_cluster_file)),
      machines_dir: expand_path(Map.get(paths, :machines_dir, default_machines_dir)),
      services_dir: expand_path(Map.get(paths, :services_dir, default_services_dir))
    }
  end

  def system_editor do
    System.get_env("VISUAL") || System.get_env("EDITOR") || "vi"
  end

  def machine_files(paths) do
    paths
    |> normalize_paths()
    |> Map.fetch!(:machines_dir)
    |> nix_files_in_dir()
  end

  def service_files(paths) do
    paths
    |> normalize_paths()
    |> Map.fetch!(:services_dir)
    |> nix_files_in_dir()
  end

  def machine_file_for_node(paths, node_name) when is_atom(node_name) do
    machine_file_for_node(paths, Atom.to_string(node_name))
  end

  def machine_file_for_node(paths, node_name) when is_binary(node_name) do
    Enum.find(machine_files(paths), fn path ->
      machine_node_name(path) == node_name
    end)
  end

  def service_file_for_name(paths, service_name) when is_binary(service_name) do
    path =
      paths
      |> normalize_paths()
      |> Map.fetch!(:services_dir)
      |> Path.join("#{service_name}.nix")

    if File.exists?(path), do: path, else: nil
  end

  def cluster_file(paths) do
    paths
    |> normalize_paths()
    |> Map.fetch!(:cluster_file)
  end

  def file_preview(nil), do: "No file is selected."

  def file_preview(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, :enoent} -> "File does not exist yet:\n#{path}"
      {:error, reason} -> "Failed to read #{path}:\n#{:file.format_error(reason)}"
    end
  end

  def add_machine(paths, node_name, opts \\ []) when is_binary(node_name) do
    with :ok <- validate_generated_name(node_name, "node name") do
      node_name = String.trim(node_name)
      paths = normalize_paths(paths)
      output = next_machine_path(paths, node_name)
      cookie_file = existing_cookie_file(paths)

      deploy_host =
        opts |> Keyword.get(:deploy_host, node_host(node_name)) |> to_string() |> String.trim()

      labels = opts |> Keyword.get(:labels, []) |> normalize_label_list()
      module_path = relative_nix_path(Path.join(paths.source, "nix/nix-swarm/module.nix"), output)
      cluster_path = relative_nix_path(paths.cluster_file, output)

      content = """
      { lib, ... }:
      {
        imports = [
          (import #{module_path})
          #{cluster_path}
        ];

        # This host file bootstraps the runtime onto a new machine.
        # Keep the shared peer/service definitions in the shared cluster module.
        services.nix-swarm = {
          enable = true;
          nodeName = #{NixSwarm.nix_string_literal(node_name)};
          cookieFile = #{NixSwarm.nix_string_literal(cookie_file)};
          peers = lib.mkAfter [ #{NixSwarm.nix_string_literal(node_name)} ];
          nodes.#{nix_attr_name(node_name)} = {
            labels = #{nix_string_list(labels)};
            deployHost = #{NixSwarm.nix_string_literal(deploy_host)};
            nixosConfiguration = #{NixSwarm.nix_string_literal(Path.basename(output, ".nix"))};
          };
          # Keep distribution ports closed on public interfaces. Scope any
          # firewall rule to a private or overlay-network interface.
          openFirewall = false;
        };
      }
      """

      File.mkdir_p!(Path.dirname(output))
      File.write!(output, content)
      {:ok, output}
    end
  end

  def add_service(paths, service_name, opts \\ []) when is_binary(service_name) do
    with :ok <- validate_generated_name(service_name, "service name") do
      service_name = String.trim(service_name)
      paths = normalize_paths(paths)
      output = Path.join(paths.services_dir, "#{service_name}.nix")

      if File.exists?(output) do
        {:error, "service file already exists: #{output}"}
      else
        File.mkdir_p!(Path.dirname(output))

        File.write!(
          output,
          """
          { ... }:
          {
          #{module_import_entry(Keyword.get(opts, :module_content))}
            # Configure the NixOS service backing #{service_name} here.
            services.nix-swarm.services.#{nix_attr_name(service_name)} = {
              replicas = #{normalize_replicas(Keyword.get(opts, :replicas, 1))};
          #{unit_template_entry(Keyword.get(opts, :unit_template))}
              constraints = #{nix_string_list(normalize_label_list(Keyword.get(opts, :constraints, [])))};
              preferredNodes = #{nix_string_list(normalize_node_list(Keyword.get(opts, :preferred_nodes, Keyword.get(opts, :preferredNodes, []))))};
            };
          }
          """
        )

        {:ok, output}
      end
    end
  end

  def delete_machine_file(nil), do: {:error, "no machine file is selected"}

  def delete_machine_file(path) do
    case File.rm(path) do
      :ok -> {:ok, path}
      {:error, :enoent} -> {:error, "machine file does not exist: #{path}"}
      {:error, reason} -> {:error, "failed to delete #{path}: #{:file.format_error(reason)}"}
    end
  end

  def delete_machine(paths, path) do
    node_name = if path, do: machine_node_name(path)

    case delete_machine_file(path) do
      {:ok, deleted_path} ->
        if node_name do
          {:ok, deleted_path,
           [
             "only the generated machine file was removed; review #{cluster_file(paths)} for references to #{node_name}"
           ]}
        else
          {:ok, deleted_path,
           ["machine file did not contain a nodeName; cluster topology was not updated"]}
        end

      {:error, _message} = error ->
        error
    end
  end

  def delete_service(paths, service_name) when is_binary(service_name) do
    paths = normalize_paths(paths)
    path = Path.join(paths.services_dir, "#{service_name}.nix")

    with :ok <- remove_file(path) do
      {:ok, path, service_reference_warnings(paths.cluster_file, service_name)}
    end
  end

  def machine_node_name(path) do
    with {:ok, contents} <- File.read(path),
         [_, value] <- Regex.run(~r/nodeName\s*=\s*"([^"]+)"/, contents) do
      value
    else
      _ -> nil
    end
  end

  def existing_cookie_file(paths) do
    Enum.find_value(machine_files(paths), @default_cookie_file, fn path ->
      with {:ok, contents} <- File.read(path),
           [_, value] <- Regex.run(~r/cookieFile\s*=\s*"([^"]+)"/, contents) do
        value
      else
        _ -> nil
      end
    end)
  end

  def local_cookie_file(paths) do
    paths = normalize_paths(paths)

    @local_cookie_filenames
    |> Enum.map(&Path.join([paths.source, "secrets", &1]))
    |> Kernel.++([existing_cookie_file(paths), @default_cookie_file])
    |> Enum.uniq()
    |> Enum.find(&(is_binary(&1) and File.exists?(&1)))
  end

  def default_target(paths) do
    paths = normalize_paths(paths)

    with {:ok, contents} <- File.read(paths.cluster_file),
         [_, peers_block] <- Regex.run(~r/peers\s*=\s*\[(.*?)\];/ms, contents),
         [[target] | _rest] <- Regex.scan(~r/"([^"]+)"/, peers_block, capture: :all_but_first) do
      target
    else
      _ -> nil
    end
  end

  defp next_machine_path(paths, node_name) do
    base =
      node_name
      |> String.split("@")
      |> hd()
      |> String.replace(~r/[^a-zA-Z0-9_.-]/, "-")
      |> case do
        "" -> "node"
        value -> value
      end

    Enum.reduce_while(0..1000, nil, fn index, _acc ->
      suffix = if index == 0, do: "", else: "-#{index + 1}"
      candidate = Path.join(paths.machines_dir, "#{base}#{suffix}.nix")

      if File.exists?(candidate) do
        {:cont, nil}
      else
        {:halt, candidate}
      end
    end)
  end

  defp unit_template_entry(nil), do: ""

  defp unit_template_entry(template) do
    "      unitTemplate = #{NixSwarm.nix_string_literal(to_string(template))};"
  end

  defp module_import_entry(nil), do: ""

  defp module_import_entry(content) do
    "  imports = [ (\n#{String.trim(content)}\n  ) ];\n"
  end

  defp service_reference_warnings(cluster_file, service_name) do
    case File.read(cluster_file) do
      {:ok, contents} ->
        warnings = []

        warnings =
          if String.contains?(contents, "./services/#{service_name}.nix"),
            do: ["cluster.nix still imports services/#{service_name}.nix" | warnings],
            else: warnings

        warnings =
          if String.contains?(contents, "services.#{service_name}"),
            do: ["cluster.nix still references services.#{service_name}" | warnings],
            else: warnings

        warnings =
          if String.contains?(contents, "ingress.sites.#{service_name}"),
            do: ["cluster.nix still references ingress.sites.#{service_name}" | warnings],
            else: warnings

        warnings =
          if String.contains?(contents, "service = #{NixSwarm.nix_string_literal(service_name)}"),
            do: ["cluster.nix still routes to service #{service_name}" | warnings],
            else: warnings

        Enum.reverse(warnings)

      {:error, _reason} ->
        []
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, "service file does not exist: #{path}"}
      {:error, reason} -> {:error, "failed to delete #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp nix_files_in_dir(dir) do
    dir
    |> Path.join("*.nix")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp relative_nix_path(target, from_file) do
    from_dir = Path.dirname(from_file)

    target_parts = Path.split(Path.expand(target))
    from_parts = Path.split(Path.expand(from_dir))

    {target_tail, from_tail} = strip_common_prefix(target_parts, from_parts)

    path =
      List.duplicate("..", length(from_tail))
      |> Kernel.++(target_tail)
      |> case do
        [] -> "."
        parts -> Path.join(parts)
      end

    if String.starts_with?(path, ".") do
      path
    else
      "./" <> path
    end
  end

  defp strip_common_prefix([part | target_rest], [part | from_rest]),
    do: strip_common_prefix(target_rest, from_rest)

  defp strip_common_prefix(target_parts, from_parts), do: {target_parts, from_parts}

  defp nix_attr_name(value), do: NixSwarm.nix_string_literal(to_string(value))

  defp nix_string_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&NixSwarm.nix_string_literal/1)
    |> Enum.join(" ")
    |> then(&"[ #{&1} ]")
  end

  defp normalize_label_list(value) when is_binary(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_label_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_node_list(values), do: normalize_label_list(values)

  defp normalize_replicas(value) when is_integer(value) and value >= 0, do: value

  defp normalize_replicas(value) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> raise ArgumentError, "replicas must be zero or greater"
    end
  end

  defp node_host(node_name) do
    node_name
    |> String.split("@", parts: 2)
    |> List.last()
  end

  def validate_generated_name(value, label) do
    name = String.trim(value)

    cond do
      name == "" ->
        {:error, "#{label} cannot be empty"}

      not Regex.match?(@safe_generated_name_regex, name) or String.contains?(name, "..") ->
        {:error, "#{label} contains unsupported characters"}

      true ->
        :ok
    end
  end

  defp expand_path(path), do: path |> to_string() |> Path.expand()
end
