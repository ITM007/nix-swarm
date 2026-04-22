defmodule Swarm.Bootstrap do
  @moduledoc false

  @default_module_ref "inputs.swarm.nixosModules.default"
  @default_package_ref "inputs.swarm.packages.${pkgs.system}.default"
  @default_cluster_module "../cluster/cluster.nix"

  def run(opts) do
    output = Keyword.fetch!(opts, :output)
    node_name = Keyword.fetch!(opts, :node_name)
    cookie_file = Keyword.fetch!(opts, :cookie_file)
    cluster_module = Keyword.get(opts, :cluster_module, @default_cluster_module)
    module_ref = Keyword.get(opts, :module_ref, @default_module_ref)
    package_ref = Keyword.get(opts, :package_ref, @default_package_ref)
    deploy? = Keyword.get(opts, :deploy, false)
    deploy_opts = normalize_deploy_opts(opts)

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
        Swarm.Deploy.run(deploy_opts)
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
    """
    { inputs, pkgs, ... }:
    {
      imports = [
        #{module_ref}
        #{cluster_module}
      ];

      # This host file bootstraps the runtime onto a new machine.
      # Keep the shared cluster and service definitions under cluster/.
      services.swarm = {
        enable = true;
        package = #{package_ref};
        nodeName = "#{node_name}";
        cookieFile = #{cookie_file};
      };
    }
    """
  end

  defp normalize_deploy_opts(opts) do
    case {Keyword.get(opts, :hosts), Keyword.get(opts, :host)} do
      {nil, nil} -> opts
      {nil, host} -> Keyword.put(opts, :hosts, host)
      {_hosts, _host} -> opts
    end
  end
end
