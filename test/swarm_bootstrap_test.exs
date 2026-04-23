defmodule SwarmBootstrapTest do
  use ExUnit.Case, async: true

  test "add-machine writes a Nix host module" do
    output =
      Path.join(System.tmp_dir!(), "swarm-bootstrap-#{System.unique_integer([:positive])}.nix")

    result =
      Swarm.Bootstrap.run(
        output: output,
        node_name: "node-d@10.0.0.14",
        cookie_file: "/etc/nixos/nix-swarm/secrets/swarm.cookie",
        cluster_module: "../clusters/home-lab/cluster.nix"
      )

    content = File.read!(output)

    assert result.output == output
    assert content =~ "services.swarm"
    assert content =~ "node-d@10.0.0.14"
    assert content =~ "../clusters/home-lab/cluster.nix"
    refute content =~ "package ="

    File.rm_rf!(output)
  end

  test "bootstrap can still override the package reference" do
    content =
      Swarm.Bootstrap.machine_module(%{
        node_name: "node-d@10.0.0.14",
        cookie_file: "/etc/nixos/nix-swarm/secrets/swarm.cookie",
        cluster_module: "../cluster/cluster.nix",
        module_ref: "inputs.swarm.nixosModules.default",
        package_ref: "inputs.swarm.packages.${pkgs.system}.default"
      })

    assert content =~ "package = inputs.swarm.packages.${pkgs.system}.default;"
    assert content =~ "cookieFile = \"/etc/nixos/nix-swarm/secrets/swarm.cookie\";"
  end
end
