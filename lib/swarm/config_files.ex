defmodule Swarm.ConfigFiles do
  @moduledoc false

  @default_cookie_file "/etc/nixos/nix-swarm/secrets/swarm.cookie"

  def defaults(source \\ ".") do
    deploy_defaults = Swarm.Deploy.defaults(source)

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
    default_cluster_file = Path.join(source, "cluster/cluster.nix")
    default_machines_dir = Path.join(source, "machines")
    default_services_dir = Path.join(source, "cluster/services")

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

  def add_machine(paths, node_name) when is_binary(node_name) do
    if String.trim(node_name) == "" do
      {:error, "node name cannot be empty"}
    else
      paths = normalize_paths(paths)
      output = next_machine_path(paths, node_name)
      cookie_file = existing_cookie_file(paths)
      module_path = relative_nix_path(Path.join(paths.source, "nix/swarm/module.nix"), output)
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
        services.swarm = {
          enable = true;
          nodeName = "#{node_name}";
          cookieFile = #{nix_string_literal(cookie_file)};
          openFirewall = true;
          firewallInterfaces = [ "eth0" ];
        };
      }
      """

      File.mkdir_p!(Path.dirname(output))
      File.write!(output, content)
      {:ok, output}
    end
  end

  def add_service(paths, service_name) when is_binary(service_name) do
    if String.trim(service_name) == "" do
      {:error, "service name cannot be empty"}
    else
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

  def delete_service(paths, service_name) when is_binary(service_name) do
    paths = normalize_paths(paths)
    path = Path.join(paths.services_dir, "#{service_name}.nix")

    with :ok <- remove_file(path),
         :ok <- remove_service_import(paths.cluster_file, Path.basename(path)) do
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

  defp nix_string_literal(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("${", "\\${")

    "\"#{escaped}\""
  end

  defp expand_path(path), do: path |> to_string() |> Path.expand()
end
