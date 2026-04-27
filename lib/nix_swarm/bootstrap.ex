defmodule NixSwarm.Bootstrap do
  @moduledoc false

  @default_module_ref "inputs.nix-swarm.nixosModules.default"
  @default_cluster_module "../cluster/cluster.nix"

  def defaults do
    %{
      cluster_module: @default_cluster_module,
      module_ref: @default_module_ref,
      package_ref: "module default (import ../nix/nix-swarm/package.nix { inherit pkgs; })"
    }
  end

  def run(opts) do
    output = Keyword.fetch!(opts, :output)
    node_name = Keyword.fetch!(opts, :node_name)
    cookie_file = Keyword.fetch!(opts, :cookie_file)
    cluster_module = Keyword.get(opts, :cluster_module, @default_cluster_module)
    module_ref = Keyword.get(opts, :module_ref, @default_module_ref)
    package_ref = Keyword.get(opts, :package_ref)
    deploy? = Keyword.get(opts, :deploy, false)
    deploy_opts = normalize_deploy_opts(opts)

    unless String.starts_with?(cookie_file, "/") do
      raise ArgumentError,
            "--cookie-file must be an absolute path on the target machine (for example /etc/nixos/nix-swarm/secrets/nix-swarm.cookie)"
    end

    content =
      machine_module(%{
        node_name: node_name,
        cookie_file: cookie_file,
        cluster_module: cluster_module,
        module_ref: module_ref,
        package_ref: package_ref
      })

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, content)

    deploy_output =
      if deploy? do
        NixSwarm.Deploy.run(deploy_opts)
      end

    %{
      output: output,
      deployed: deploy?,
      deploy_output: deploy_output
    }
  end

  def machine_module(%{
        node_name: node_name,
        cookie_file: cookie_file,
        cluster_module: cluster_module,
        module_ref: module_ref,
        package_ref: package_ref
      }) do
    service_lines =
      [
        "    enable = true;",
        if(package_ref, do: "    package = #{package_ref};"),
        "    nodeName = \"#{node_name}\";",
        "    cookieFile = #{nix_string_literal(cookie_file)};"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    """
    { inputs, pkgs, ... }:
    {
      imports = [
        #{module_ref}
        #{cluster_module}
      ];

      # This host file bootstraps the runtime onto a new machine.
      # Keep the shared cluster and service definitions under cluster/.
      services.nix-swarm = {
    #{service_lines}
      };
    }
    """
  end

  defp nix_string_literal(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("${", "\\${")

    "\"#{escaped}\""
  end

  defp normalize_deploy_opts(opts) do
    case {Keyword.get(opts, :hosts), Keyword.get(opts, :host)} do
      {nil, nil} -> opts
      {nil, host} -> Keyword.put(opts, :hosts, host)
      {_hosts, _host} -> opts
    end
  end
end
