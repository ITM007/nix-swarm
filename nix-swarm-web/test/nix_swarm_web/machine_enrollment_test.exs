defmodule NixSwarmWeb.MachineEnrollmentTest do
  use ExUnit.Case, async: true

  alias NixSwarmWeb.MachineEnrollment

  test "renders a machine module and central inventory snippet" do
    params = %{
      "hostname" => "node-d",
      "deploy_host" => "root@node-d",
      "nixos_configuration" => "node-d",
      "firewall_interface" => "wg0",
      "peers" => "node-a@cluster\nnode-b@cluster"
    }

    assert {:ok, result} = MachineEnrollment.generate(params)
    assert result.filename == "machine-node-d.nix"
    assert result.machine_config =~ ~s(nodeName = "nix-swarm@node-d";)

    assert result.machine_config =~
             ~s(cookieFile = "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie";)

    assert result.machine_config =~ ~s(firewallInterfaces = [ "wg0" ];)
    assert result.machine_config =~ ~s("node-a@cluster")
    assert result.machine_config =~ ~s("node-b@cluster")
    assert result.machine_config =~ ~s("nix-swarm@node-d")
    assert result.inventory_snippet =~ ~s("nix-swarm@node-d" = {)
    assert result.inventory_snippet =~ ~s(deployHost = "root@node-d";)
    assert result.inventory_snippet =~ ~s(nixosConfiguration = "node-d";)
    refute result.machine_config =~ "secret value"
  end

  test "rejects unsafe or incomplete machine details" do
    assert {:error, errors} =
             MachineEnrollment.generate(%{
               "hostname" => "node d; rm -rf /",
               "deploy_host" => "root@node-d",
               "nixos_configuration" => "node-d",
               "firewall_interface" => "wg0",
               "peers" => "node-a@cluster"
             })

    assert "hostname contains unsupported characters" in errors
  end

  test "bounds generated input" do
    assert {:error, errors} =
             MachineEnrollment.generate(%{
               "hostname" => String.duplicate("a", 254),
               "deploy_host" => "root@node-d",
               "nixos_configuration" => "node-d",
               "firewall_interface" => "wg0",
               "peers" => "node-a@cluster"
             })

    assert "hostname is too long" in errors
  end
end
