defmodule NixSwarmBootstrapTest do
  use ExUnit.Case, async: true

  test "add-machine writes a Nix host module" do
    output =
      Path.join(
        System.tmp_dir!(),
        "nix-swarm-bootstrap-#{System.unique_integer([:positive])}.nix"
      )

    result =
      NixSwarm.Bootstrap.run(
        output: output,
        node_name: "node-d@10.0.0.14",
        cookie_file: "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie",
        cluster_module: "../clusters/home-lab/cluster.nix"
      )

    content = File.read!(output)

    assert result.output == output
    assert content =~ "services.nix-swarm"
    assert content =~ "node-d@10.0.0.14"
    assert content =~ "../clusters/home-lab/cluster.nix"
    refute content =~ "package ="

    File.rm_rf!(output)
  end

  test "bootstrap can still override the package reference" do
    content =
      NixSwarm.Bootstrap.machine_module(%{
        node_name: "node-d@10.0.0.14",
        cookie_file: "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie",
        cluster_module: "../cluster/cluster.nix",
        module_ref: "inputs.nix-swarm.nixosModules.default",
        package_ref: "inputs.nix-swarm.packages.${pkgs.system}.default"
      })

    assert content =~ "package = inputs.nix-swarm.packages.${pkgs.system}.default;"
    assert content =~ "cookieFile = \"/etc/nixos/nix-swarm/secrets/nix-swarm.cookie\";"
  end
end
