defmodule SwarmDeployTest do
  use ExUnit.Case, async: true

  test "hosts parses comma-separated host list" do
    assert Swarm.Deploy.hosts(hosts: "nixos-2, root@nixos-3 ,10.0.0.9") == [
             "nixos-2",
             "root@nixos-3",
             "10.0.0.9"
           ]
  end

  test "rebuild command includes optional flake and build host" do
    command = Swarm.Deploy.rebuild_command(flake: ".#nixos-2", build_host: "builder@10.0.0.10")

    assert command ==
             "'nixos-rebuild' 'switch' '--flake' '.#nixos-2' '--build-host' 'builder@10.0.0.10'"
  end

  test "sync command targets the managed repo path" do
    command = Swarm.Deploy.sync_command("/tmp/swarm", "root@nixos-2", "/etc/nixos/nix-swarm")

    assert command =~ "cd '/tmp/swarm'"
    assert command =~ "ssh 'root@nixos-2'"
    assert command =~ "/etc/nixos/nix-swarm"
    assert command =~ "chmod 600 \"$remote_path/secrets/swarm.cookie\""
  end

  test "validation commands evaluate machine modules through nixos eval-config" do
    commands = Swarm.Deploy.validation_commands(["/tmp/swarm/machines/nixos-2.nix"])

    assert commands == [
             "nix-instantiate --eval --strict --expr 'let eval = import <nixpkgs/nixos/lib/eval-config.nix> {\n  system = builtins.currentSystem;\n  modules = [ /tmp/swarm/machines/nixos-2.nix ];\n  specialArgs = { inputs = {}; };\n}; in {\n  node = eval.config.services.swarm.nodeName;\n  peers = eval.config.services.swarm.peers;\n  services = builtins.attrNames eval.config.services.swarm.services;\n  ingress = builtins.attrNames eval.config.services.swarm.ingress.sites;\n}'"
           ]
  end

  test "plan builds dry-run result commands per host" do
    source = Path.expand("..", __DIR__)
    plan = Swarm.Deploy.plan(hosts: "nixos-2,nixos-3", source: source, dry_run: true)

    assert plan.dry_run
    assert length(plan.validation.machine_files) >= 2
    assert Enum.any?(plan.validation.commands, &String.contains?(&1, "eval-config.nix"))
    assert Enum.map(plan.results, & &1.host) == ["nixos-2", "nixos-3"]
    assert Enum.all?(plan.results, &String.contains?(&1.sync_command, "/etc/nixos/nix-swarm"))
    assert Enum.all?(plan.results, &String.contains?(&1.rebuild_command, "nixos-rebuild"))
  end
end
