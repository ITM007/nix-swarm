defmodule NixSwarm.Cluster.Ensure do
  @moduledoc """
  Ensures every machine in the cluster config is running nix-swarmd.

  Reads cluster.nix, connects to each deployHost, checks swarmd status,
  and bootstraps any machine that isn't set up.
  """
  alias NixSwarm.ConfigFiles

  @default_nixos_dir "/etc/nixos"
  @default_swarm_path "/etc/nixos/nix-swarm"

  def run(opts \\ []) do
    paths = ConfigFiles.normalize_paths(%{})
    source = Keyword.get(opts, :source, paths.source)
    cluster_file = Keyword.get(opts, :cluster_file, paths.cluster_file)
    cookie = Keyword.get(opts, :cookie) || ensure_cookie(paths)
    force? = Keyword.get(opts, :force, false)

    with {:ok, nodes} <- parse_cluster_nodes(cluster_file) do
      results =
        Enum.map(nodes, fn {node_name, deploy_host} ->
          ensure_node(source, node_name, deploy_host, cookie, force?)
        end)

      %{nodes: results, ok: Enum.all?(results, &(&1.status == :ok))}
    end
  end

  defp parse_cluster_nodes(cluster_file) do
    case File.read(cluster_file) do
      {:ok, contents} ->
        node_entries =
          Regex.scan(
            ~r/"([^"]+)"\s*=\s*\{[^}]*deployHost\s*=\s*"([^"]+)"/s,
            contents,
            capture: :all_but_first
          )
          |> Enum.map(fn [name, host] -> {name, host} end)

        case node_entries do
          [] -> {:error, "no nodes with deployHost found in #{cluster_file}"}
          entries -> {:ok, entries}
        end

      {:error, reason} ->
        {:error, "cannot read #{cluster_file}: #{:file.format_error(reason)}"}
    end
  end

  defp ensure_node(source, node_name, deploy_host, cookie, force?) do
    host = extract_ssh_host(deploy_host)

    case check_remote(host) do
      {:ok, :running} when not force? ->
        %{node: node_name, host: host, status: :ok, action: :skip, message: "already running"}

      {:ok, :running} ->
        %{
          node: node_name,
          host: host,
          status: :ok,
          action: :update,
          result: update_remote(source, host)
        }

      {:ok, :not_running} ->
        %{
          node: node_name,
          host: host,
          status: :ok,
          action: :bootstrap,
          result: bootstrap_remote(source, host, node_name, cookie)
        }

      {:error, reason} ->
        %{node: node_name, host: host, status: :error, action: :check_failed, message: reason}
    end
  end

  defp check_remote(host) do
    case ssh(host, "systemctl is-active nix-swarmd 2>/dev/null || echo not-running") do
      {:ok, output} ->
        if String.trim(output) == "active", do: {:ok, :running}, else: {:ok, :not_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bootstrap_remote(source, host, node_name, cookie) do
    with :ok <- create_remote_dirs(host),
         :ok <- sync_source(source, host),
         :ok <- maybe_create_flake(host),
         :ok <- create_machine_config(host, node_name),
         :ok <- copy_cookie(host, cookie),
         :ok <- rebuild_remote(host) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_remote(source, host) do
    with :ok <- sync_source(source, host),
         :ok <- rebuild_remote(host) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_remote_dirs(host) do
    ssh(host, "mkdir -p #{@default_swarm_path} #{@default_nixos_dir}")
    |> map_ssh_result("create directories")
  end

  defp sync_source(source, host) do
    tar_excludes = [".git", ".serena", "result", "_build", "deps"]

    tar_args =
      tar_excludes
      |> Enum.map_join(" ", fn e -> "--exclude=#{shell_escape(e)}" end)
      |> then(&"tar #{&1} -czf - -C #{shell_escape(source)} .")

    remote_extract = "mkdir -p #{@default_swarm_path} && tar -xzf - -C #{@default_swarm_path}"

    cmd = "#{tar_args} | #{ssh_command(host, remote_extract)}"

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, "sync failed (status #{status}): #{String.trim(output)}"}
    end
  end

  defp maybe_create_flake(host) do
    case ssh(host, "test -f #{@default_nixos_dir}/flake.nix && echo exists || echo missing") do
      {:ok, "exists\n"} ->
        :ok

      {:ok, _} ->
        ssh(
          host,
          "cat > #{@default_nixos_dir}/flake.nix << 'NIXEOF'\n#{default_flake_template()}\nNIXEOF\n"
        )
        |> map_ssh_result("create flake.nix")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_machine_config(host, node_name) do
    machine_content = """
    { inputs, ... }:
    {
      imports = [
        inputs.nix-swarm.nixosModules.default
        inputs.nix-swarm + "/cluster/cluster.nix"
      ];

      services.nix-swarm = {
        enable = true;
        nodeName = "#{node_name}";
        cookieFile = "/etc/nixos/nix-swarm/secrets/swarm.cookie";
        openFirewall = true;
      };
    }
    """

    ssh_cmd = "cat > #{@default_nixos_dir}/machine.nix << 'NIXEOF'\n#{machine_content}\nNIXEOF\n"

    # Also ensure configuration.nix imports machine.nix
    ensure_import_cmd = """
    if [ -f #{@default_nixos_dir}/configuration.nix ]; then
      grep -q machine.nix #{@default_nixos_dir}/configuration.nix || \
        echo './machine.nix' >> #{@default_nixos_dir}/configuration.nix;
    else
      echo '{ ... }: { imports = [ ./machine.nix ]; }' > #{@default_nixos_dir}/configuration.nix;
    fi
    """

    with {:ok, _} <- ssh(host, ssh_cmd) |> map_ssh_result("create machine.nix"),
         {:ok, _} <- ssh(host, ensure_import_cmd) |> map_ssh_result("update configuration.nix") do
      :ok
    end
  end

  defp copy_cookie(host, cookie) do
    ssh_cmd =
      "mkdir -p #{@default_swarm_path}/secrets && printf '%s' #{shell_escape(cookie)} > #{@default_swarm_path}/secrets/swarm.cookie && chmod 600 #{@default_swarm_path}/secrets/swarm.cookie"

    ssh(host, ssh_cmd) |> map_ssh_result("copy cookie")
  end

  defp rebuild_remote(host) do
    ssh(host, "nixos-rebuild switch --flake #{@default_nixos_dir} 2>&1")
    |> map_ssh_result("rebuild")
  end

  defp ssh(host, command) do
    full_cmd = ssh_command(host, command)

    case System.cmd("sh", ["-c", full_cmd], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, "SSH failed (status #{status}): #{String.trim(output)}"}
    end
  end

  defp ssh_command(host, remote_command) do
    [
      "ssh",
      "-F",
      "/dev/null",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=10",
      "-o",
      "StrictHostKeyChecking=accept-new",
      "--",
      host,
      remote_command
    ]
    |> Enum.map_join(" ", &shell_escape/1)
  end

  defp map_ssh_result({:ok, _output}, _label), do: :ok
  defp map_ssh_result({:error, reason}, label), do: {:error, "#{label}: #{reason}"}

  defp extract_ssh_host(deploy_host) do
    # deployHost can be "root@overlord" or just "192.168.1.100"
    # If it has no @, use root@
    if String.contains?(deploy_host, "@") do
      deploy_host
    else
      "root@#{deploy_host}"
    end
  end

  defp ensure_cookie(paths) do
    cookie_file = ConfigFiles.local_cookie_file(paths)

    cond do
      # Try age-encrypted cookie first (GitOps workflow)
      cookie_file && File.exists?(cookie_file <> ".age") ->
        NixSwarm.Secrets.decrypt_age(cookie_file <> ".age")

      # Try plaintext cookie
      cookie_file && File.exists?(cookie_file) ->
        cookie_file |> File.read!() |> String.trim()

      # Generate a new cookie
      true ->
        cookie = generate_cookie()
        save_cookie(paths, cookie)
        cookie
    end
  end

  defp generate_cookie do
    # Simple alphanumeric cookie — no base64 chars to avoid regex issues
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
    |> String.replace(~r/[^A-Za-z0-9]/, "")
    |> String.slice(0, 16)
  end

  defp save_cookie(paths, cookie) do
    secrets_dir = Path.join(paths.source, "secrets")
    cookie_path = Path.join(secrets_dir, "swarm.cookie")
    File.mkdir_p!(secrets_dir)
    File.write!(cookie_path, cookie)
    IO.puts(:stderr, "  generated new swarm cookie at #{cookie_path}")

    cookie_path
  end

  defp shell_escape(value), do: "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"

  defp default_flake_template do
    ~s'''
    {
      description = "Nix-Swarm managed node";

      inputs = {
        nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
        nix-swarm.url = "path:/etc/nixos/nix-swarm";
        nix-swarm.inputs.nixpkgs.follows = "nixpkgs";
      };

      outputs = { self, nixpkgs, nix-swarm }:
        let
          system = "x86_64-linux";
          pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
        in
        {
          nixosConfigurations.default = nixpkgs.lib.nixosSystem {
            specialArgs = { inputs = { inherit nix-swarm; }; };
            modules = [
              ({ ... }: { nixpkgs.config.allowUnfree = true; })
              ./configuration.nix
            ];
          };
        };
    }
    '''
  end
end
