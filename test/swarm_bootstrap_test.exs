defmodule SwarmBootstrapTest do
  use ExUnit.Case, async: true

  test "add-machine writes a Nix host module" do
    output =
      Path.join(System.tmp_dir!(), "swarm-bootstrap-#{System.unique_integer([:positive])}.nix")

    result =
      Swarm.Bootstrap.run(
        output: output,
        node_name: "node-d@10.0.0.14",
        cookie_file: "../secrets/swarm.cookie",
        cluster_module: "../clusters/home-lab/cluster.nix",
        package_ref: "inputs.swarm.packages.${pkgs.system}.default"
      )

    content = File.read!(output)

    assert result.output == output
    assert content =~ "services.swarm"
    assert content =~ "node-d@10.0.0.14"
    assert content =~ "../clusters/home-lab/cluster.nix"
    assert content =~ "inputs.swarm.packages.${pkgs.system}.default"

    File.rm_rf!(output)
  end
end
