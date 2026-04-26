defmodule SwarmDeployTest do
  use ExUnit.Case, async: true

  test "hosts parses comma-separated host list" do
    assert Swarm.Deploy.hosts(hosts: "nixos-2, root@nixos-3 ,10.0.0.9") == [
             "nixos-2",
             "root@nixos-3",
             "10.0.0.9"
           ]
  end

  test "hosts defaults to all machine file basenames" do
    source = Path.expand("..", __DIR__)

    assert Swarm.Deploy.hosts([], source) == ["nixos-2", "nixos-3", "overlord"]
  end

  test "rebuild command includes nixos-config when using non-flake rebuilds" do
    command = Swarm.Deploy.rebuild_command([], "/etc/nixos")

    assert command ==
             "'nixos-rebuild' 'switch' '-I' 'nixos-config=/etc/nixos/configuration.nix'"
  end

  test "rebuild command includes optional flake and build host" do
    command = Swarm.Deploy.rebuild_command(flake: ".#nixos-2", build_host: "builder@10.0.0.10")

    assert command ==
             "'nixos-rebuild' 'switch' '--flake' '.#nixos-2' '--build-host' 'builder@10.0.0.10'"
  end

  test "sync command targets the managed repo path" do
    command = Swarm.Deploy.sync_command("/tmp/swarm", "root@nixos-2", "/etc/nixos/nix-swarm")

    assert command =~ "cd '/tmp/swarm'"
    assert command =~ "ssh -- 'root@nixos-2'"
    assert command =~ "/etc/nixos/nix-swarm"
    assert command =~ "sudo -n true"
    assert command =~ "as_root mkdir -p \"$staging\""
    assert command =~ "as_root tar -xzf - -C \"$staging\""
    assert command =~ "cp -an \"$backup/secrets/.\" \"$remote_path/secrets/\""
    assert command =~ "chown root:root \"$remote_path/secrets\""
    assert command =~ "chmod 711 \"$remote_path/secrets\""
    assert command =~ "chown root:root \"$remote_path/secrets/swarm.cookie\""
    assert command =~ "chmod 600 \"$remote_path/secrets/swarm.cookie\""
  end

  test "rebuild host command elevates nixos-rebuild when needed" do
    command = Swarm.Deploy.rebuild_host_command("nixos-2", "/etc/nixos", flake: ".#nixos-2")

    assert command =~ "ssh -- 'nixos-2'"
    assert command =~ "sudo -n true"
    assert command =~ "as_root"
    assert command =~ "'nixos-rebuild'"
    assert command =~ "'--flake'"
    assert command =~ "'.#nixos-2'"
    assert command =~ "remote rebuild requires root or passwordless sudo"
  end

  test "rebuild host command uses explicit nixos-config for non-flake rebuilds" do
    command = Swarm.Deploy.rebuild_host_command("root@overlord", "/etc/nixos", [])

    assert command =~ "ssh -- 'root@overlord'"
    assert command =~ "'-I'"
    assert command =~ "'nixos-config=/etc/nixos/configuration.nix'"
  end

  test "validation commands evaluate machine modules through nixos eval-config" do
    commands = Swarm.Deploy.validation_commands(["/tmp/swarm/machines/nixos-2.nix"])

    assert commands == [
             "nix-instantiate --eval --strict --expr 'let eval = import <nixpkgs/nixos/lib/eval-config.nix> {\n  system = builtins.currentSystem;\n  modules = [ (builtins.toPath \"/tmp/swarm/machines/nixos-2.nix\") ];\n  specialArgs = { inputs = {}; };\n}; in {\n  node = eval.config.services.swarm.nodeName;\n  peers = eval.config.services.swarm.peers;\n  services = builtins.attrNames eval.config.services.swarm.services;\n  ingress = builtins.attrNames eval.config.services.swarm.ingress.sites;\n}'"
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

  test "plan targets all machine files by default" do
    source = Path.expand("..", __DIR__)
    plan = Swarm.Deploy.plan(source: source)

    assert Enum.map(plan.results, & &1.host) == ["nixos-2", "nixos-3", "overlord"]
  end

  test "plan accepts defaults maps for update flows" do
    source = Path.expand("..", __DIR__)
    plan = Swarm.Deploy.plan(Swarm.Deploy.defaults(source))

    assert plan.source == source
    assert Enum.map(plan.results, & &1.host) == ["nixos-2", "nixos-3", "overlord"]
  end
end
