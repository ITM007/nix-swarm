defmodule NixSwarm.Cluster.Rebuild do
  @moduledoc """
  Rebuilds remote NixOS machines by SSHing into each deployHost.

  For each node in cluster.nix, SSHs into the machine and runs:
      cd /home/itm/NixFiles && nixos-rebuild switch --impure --flake .#<hostname>
  """

  alias NixSwarm.ConfigFiles

  def run(opts \\ []) do
    source = Keyword.get(opts, :source)
    paths = if source, do: ConfigFiles.defaults(source), else: ConfigFiles.normalize_paths(%{})
    cluster_file = Keyword.get(opts, :cluster_file, paths.cluster_file)

    IO.puts("Rebuilding cluster nodes from #{cluster_file}\n")

    case parse_nodes(cluster_file) do
      {:ok, nodes} when nodes == [] ->
        {:error, "no nodes with deployHost found in #{cluster_file}"}

      {:ok, nodes} ->
        results = Enum.map(nodes, fn {_name, deploy_host} -> rebuild_node(deploy_host) end)
        %{nodes: results, ok: Enum.all?(results, &(&1.status == :ok))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_nodes(cluster_file) do
    case File.read(cluster_file) do
      {:ok, contents} ->
        entries =
          Regex.scan(
            ~r/deployHost\s*=\s*"([^"]+)"/s,
            contents,
            capture: :all_but_first
          )
          |> Enum.uniq()
          |> Enum.map(fn [host] -> {extract_nixos_hostname(host), host} end)

        {:ok, entries}

      {:error, reason} ->
        {:error, "cannot read #{cluster_file}: #{:file.format_error(reason)}"}
    end
  end

  defp rebuild_node(deploy_host) do
    target = extract_ssh_host(deploy_host)
    hostname = extract_nixos_hostname(deploy_host)

    IO.puts("  #{hostname}: rebuilding via #{target}...")

    remote_cmd = """
    cd /home/itm/NixFiles && \
    nix flake lock --update-input nix-swarm --extra-experimental-features 'nix-command flakes' 2>&1 && \
    nixos-rebuild switch --impure --flake .##{hostname} 2>&1
    """
    ssh_args = ssh_command(target, remote_cmd)

    case System.cmd("sh", ["-c", ssh_args], stderr_to_stdout: true) do
      {output, 0} ->
        IO.puts("  #{hostname}: OK")
        %{hostname: hostname, status: :ok, action: :rebuild, output: output}

      {output, status} ->
        short = String.slice(output, 0, 5000)
        IO.puts("  #{hostname}: ERROR (exit #{status})\n#{short}")
        %{hostname: hostname, status: :error, action: :rebuild, message: "exit #{status}"}
    end
  end

  defp extract_ssh_host(deploy_host) do
    if String.contains?(deploy_host, "@") do
      deploy_host
    else
      "root@#{deploy_host}"
    end
  end

  defp extract_nixos_hostname(deploy_host) do
    # "root@overlord" or "root@overlord:31300" or "overlord" -> "overlord"
    deploy_host
    |> String.replace(~r/:\d+$/, "")
    |> String.split("@")
    |> List.last()
  end

  defp ssh_command(host, remote_command) do
    {ssh_host, port_opts} = extract_ssh_port(host)

    [
      "ssh", "-F", "/dev/null",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=10",
      "-o", "StrictHostKeyChecking=accept-new",
      "-o", "UserKnownHostsFile=/dev/null"
    ] ++ port_opts ++ ["--", ssh_host, remote_command]
    |> Enum.map_join(" ", &shell_escape/1)
  end

  defp extract_ssh_port(host) do
    case Regex.run(~r/^(.+):(\d+)$/, host, capture: :all_but_first) do
      [h, port] -> {h, ["-p", port]}
      nil ->
        case System.get_env("NIX_SWARM_SSH_PORT") do
          nil -> {host, []}
          port -> {host, ["-p", port]}
        end
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
