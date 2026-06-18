defmodule NixSwarm.ConfigFiles do
  @moduledoc false

  @default_cookie_file "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie"
  @local_cookie_filenames ["nix-swarm.cookie", "swarm.cookie"]
  @safe_generated_name_regex ~r/^[A-Za-z0-9][A-Za-z0-9_.@-]*$/

  def defaults(source \\ nil) do
    deploy_defaults = NixSwarm.Deploy.defaults(source)

    normalize_paths(%{
      source: deploy_defaults.source,
      cluster_file: deploy_defaults.cluster_file,
      machines_dir: deploy_defaults.machines_dir,
      services_dir: Path.join(deploy_defaults.source, "cluster/services"),
      remote_path: deploy_defaults.remote_path,
      nixos_dir: deploy_defaults.nixos_dir
    })
  end

  def normalize_paths(paths) when is_map(paths) do
    source = expand_path(Map.get(paths, :source, "."))
    deploy_defaults = NixSwarm.Deploy.defaults(source)
    default_cluster_file = deploy_defaults.cluster_file
    default_machines_dir = deploy_defaults.machines_dir
    default_services_dir = Path.join(Path.dirname(default_cluster_file), "services")

    %{
      source: source,
      cluster_file: expand_path(Map.get(paths, :cluster_file, default_cluster_file)),
      machines_dir: expand_path(Map.get(paths, :machines_dir, default_machines_dir)),
      services_dir: expand_path(Map.get(paths, :services_dir, default_services_dir)),
      remote_path: Map.get(paths, :remote_path, "/etc/nixos/nix-swarm"),
      nixos_dir: Map.get(paths, :nixos_dir, "/etc/nixos")
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
      { inputs, pkgs, ... }:
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
          openFirewall = true;
          firewallInterfaces = [ "eth0" ];
        };
      }
      """

      File.mkdir_p!(Path.dirname(output))
      File.write!(output, content)
      update_machine_topology!(paths.cluster_file, node_name, deploy_host, labels)
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
            # Configure the NixOS service backing #{service_name} here.
            # Cluster placement and ingress stay in cluster/cluster.nix.
          }
          """
        )

        ensure_service_import(paths.cluster_file, Path.basename(output))

        ensure_service_entry!(
          paths.cluster_file,
          service_name,
          Keyword.get(opts, :replicas, 1),
          Keyword.get(opts, :constraints, []),
          Keyword.get(opts, :preferred_nodes, Keyword.get(opts, :preferredNodes, []))
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
          {:ok, deleted_path, remove_machine_topology(paths, node_name)}
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

    with :ok <- remove_file(path),
         :ok <- remove_service_import(paths.cluster_file, Path.basename(path)),
         :ok <- remove_service_entry(paths.cluster_file, service_name),
         :ok <- remove_ingress_entry(paths.cluster_file, service_name) do
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

  defp ensure_service_import(cluster_file, service_filename) do
    cluster_contents = File.read!(cluster_file)
    import_line = "    ./services/#{service_filename}"

    updated =
      cond do
        String.contains?(cluster_contents, import_line) ->
          cluster_contents

        String.contains?(cluster_contents, "imports = [") ->
          String.replace(cluster_contents, "imports = [", "imports = [\n#{import_line}",
            global: false
          )

        true ->
          raise ArgumentError, "cluster file is missing an imports block: #{cluster_file}"
      end

    File.write!(cluster_file, updated)
    :ok
  end

  defp remove_service_import(cluster_file, service_filename) do
    case File.read(cluster_file) do
      {:ok, contents} ->
        updated =
          contents
          |> String.replace(~r/^\s*\.\/services\/#{Regex.escape(service_filename)}\n/m, "")
          |> String.replace(~r/^\s*\.\/services\/#{Regex.escape(service_filename)}\r\n/m, "")
          |> String.replace(~r/^\s*\.\/services\/#{Regex.escape(service_filename)}$/m, "")

        File.write!(cluster_file, updated)
        :ok

      {:error, reason} ->
        {:error, "failed to update #{cluster_file}: #{:file.format_error(reason)}"}
    end
  end

  defp update_machine_topology!(cluster_file, node_name, deploy_host, labels) do
    contents = File.read!(cluster_file)
    contents = ensure_swarm_block(contents)
    contents = ensure_peers_entry(contents, node_name)
    contents = ensure_nodes_entry(contents, node_name, deploy_host, labels)
    File.write!(cluster_file, contents)
  end

  defp ensure_swarm_block(contents) do
    if String.contains?(contents, "services.nix-swarm = {") do
      contents
    else
      String.replace(contents, ~r/\n}\s*$/s, "\n  services.nix-swarm = {\n  };\n}\n")
    end
  end

  defp ensure_peers_entry(contents, node_name) do
    peer_line = "      #{NixSwarm.nix_string_literal(node_name)};"

    cond do
      String.contains?(contents, NixSwarm.nix_string_literal(node_name)) and
          String.contains?(contents, "peers = [") ->
        contents

      String.contains?(contents, "peers = [") ->
        String.replace(contents, "peers = [", "peers = [\n#{peer_line}", global: false)

      true ->
        String.replace(
          contents,
          "services.nix-swarm = {",
          "services.nix-swarm = {\n    peers = [\n#{peer_line}\n    ];",
          global: false
        )
    end
  end

  defp ensure_nodes_entry(contents, node_name, deploy_host, labels) do
    node_attr = nix_attr_name(node_name)

    if String.contains?(contents, "#{node_attr} = {") do
      contents
    else
      entry = """
          #{node_attr} = {
            labels = #{nix_string_list(labels)};
            deployHost = #{NixSwarm.nix_string_literal(deploy_host)};
          };
      """

      cond do
        String.contains?(contents, "nodes = {") ->
          String.replace(contents, "nodes = {", "nodes = {\n#{String.trim_trailing(entry)}",
            global: false
          )

        true ->
          String.replace(
            contents,
            "services.nix-swarm = {",
            "services.nix-swarm = {\n    nodes = {\n#{String.trim_trailing(entry)}\n    };",
            global: false
          )
      end
    end
  end

  defp ensure_service_entry!(cluster_file, service_name, replicas, constraints, preferred_nodes) do
    contents = File.read!(cluster_file)
    contents = ensure_swarm_block(contents)
    service_attr = nix_attr_name(service_name)

    if String.contains?(contents, "#{service_attr} = {") and
         String.contains?(contents, "services = {") do
      :ok
    else
      entry = """
          #{service_attr} = {
            replicas = #{normalize_replicas(replicas)};
            constraints = #{nix_string_list(normalize_label_list(constraints))};
            preferredNodes = #{nix_string_list(normalize_node_list(preferred_nodes))};
          };
      """

      updated =
        if String.contains?(contents, "services = {") do
          String.replace(contents, "services = {", "services = {\n#{String.trim_trailing(entry)}",
            global: false
          )
        else
          String.replace(
            contents,
            "services.nix-swarm = {",
            "services.nix-swarm = {\n    services = {\n#{String.trim_trailing(entry)}\n    };",
            global: false
          )
        end

      File.write!(cluster_file, updated)
      :ok
    end
  end

  defp remove_machine_topology(paths, node_name) do
    paths = normalize_paths(paths)

    case File.read(paths.cluster_file) do
      {:ok, contents} ->
        updated =
          contents
          |> String.replace(
            ~r/^\s*#{Regex.escape(NixSwarm.nix_string_literal(node_name))};\n/m,
            ""
          )
          |> remove_attr_block(node_name)

        File.write!(paths.cluster_file, updated)

        [
          "review placement diagnostics before applying; removing #{node_name} may reduce capacity"
        ]

      {:error, reason} ->
        ["failed to update #{paths.cluster_file}: #{:file.format_error(reason)}"]
    end
  end

  defp remove_service_entry(cluster_file, service_name) do
    update_cluster_file(cluster_file, &remove_attr_block(&1, service_name))
  end

  defp remove_ingress_entry(cluster_file, service_name) do
    update_cluster_file(cluster_file, fn contents ->
      contents
      |> remove_attr_block("services.nix-swarm.ingress.sites.#{service_name}")
      |> remove_attr_block(service_name)
    end)
  end

  defp update_cluster_file(cluster_file, fun) do
    case File.read(cluster_file) do
      {:ok, contents} ->
        File.write!(cluster_file, fun.(contents))
        :ok

      {:error, reason} ->
        {:error, "failed to update #{cluster_file}: #{:file.format_error(reason)}"}
    end
  end

  defp remove_attr_block(contents, attr_name) do
    escaped_attr =
      attr_name
      |> nix_attr_name()
      |> Regex.escape()

    contents
    |> String.replace(~r/^\s*#{escaped_attr}\s*=\s*\{.*?^\s*\};\n/ms, "")
    |> String.replace(~r/^\s*#{Regex.escape(attr_name)}\s*=\s*\{.*?^\s*\};\n/ms, "")
  end

  defp service_reference_warnings(cluster_file, service_name) do
    case File.read(cluster_file) do
      {:ok, contents} ->
        warnings = []

        warnings =
          if String.contains?(contents, "services.#{service_name}"),
            do: ["cluster.nix still references services.#{service_name}" | warnings],
            else: warnings

        warnings =
          if String.contains?(contents, "ingress.sites.#{service_name}"),
            do: ["cluster.nix still references ingress.sites.#{service_name}" | warnings],
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

  defp validate_generated_name(value, label) do
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
