defmodule NixSwarmDeployTest do
  use ExUnit.Case, async: true

  test "hosts parses comma-separated host list" do
    assert NixSwarm.Deploy.hosts(hosts: "nixos-2, root@nixos-3 ,10.0.0.9") == [
             "nixos-2",
             "root@nixos-3",
             "10.0.0.9"
           ]
  end

  test "hosts defaults to all machine file basenames" do
    source = Path.expand("..", __DIR__)

    assert NixSwarm.Deploy.hosts([], source) == ["example-node-a", "example-node-b"]
  end

  test "rebuild command includes nixos-config when using non-flake rebuilds" do
    command = NixSwarm.Deploy.rebuild_command([], "/etc/nixos")

    assert command ==
             "'nixos-rebuild' 'switch' '-I' 'nixos-config=/etc/nixos/configuration.nix'"
  end

  test "rebuild command includes optional flake and build host" do
    command = NixSwarm.Deploy.rebuild_command(flake: ".#nixos-2", build_host: "builder@10.0.0.10")

    assert command ==
             "'nixos-rebuild' 'switch' '--flake' '.#nixos-2' '--build-host' 'builder@10.0.0.10'"
  end

  test "sync command targets the managed repo path" do
    command =
      NixSwarm.Deploy.sync_command("/tmp/nix-swarm", "root@nixos-2", "/etc/nixos/nix-swarm")

    assert command =~ "cd '/tmp/nix-swarm'"

    assert command =~
             "'ssh' '-o' 'BatchMode=yes' '-o' 'StrictHostKeyChecking=accept-new' '--' 'root@nixos-2'"

    assert command =~ "/etc/nixos/nix-swarm"
    assert command =~ "sudo -n true"
    assert command =~ "as_root mkdir -p -m 700 \"$staging\""
    assert command =~ "as_root tar -xzf - -C \"$staging\""
    assert command =~ "as_root mkdir -p -m 700 \"$remote_path/secrets\""
    assert command =~ "as_root chmod 700 \"$remote_path/secrets\""
    assert command =~ "cp -an \"$backup/secrets/.\" \"$remote_path/secrets/\""
    assert command =~ "chown root:root \"$remote_path/secrets\""
    assert command =~ "chmod 711 \"$remote_path/secrets\""
    assert command =~ "chown root:root \"$remote_path/secrets/nix-swarm.cookie\""
    assert command =~ "chmod 600 \"$remote_path/secrets/nix-swarm.cookie\""
  end

  test "rebuild host command elevates nixos-rebuild when needed" do
    command = NixSwarm.Deploy.rebuild_host_command("nixos-2", "/etc/nixos", flake: ".#nixos-2")

    assert command =~
             "'ssh' '-o' 'BatchMode=yes' '-o' 'StrictHostKeyChecking=accept-new' '--' 'nixos-2'"

    assert command =~ "sudo -n true"
    assert command =~ "as_root"
    assert command =~ "'nixos-rebuild'"
    assert command =~ "'--flake'"
    assert command =~ "'.#nixos-2'"
    assert command =~ "remote rebuild requires root or passwordless sudo"
  end

  test "rebuild host command uses explicit nixos-config for non-flake rebuilds" do
    command = NixSwarm.Deploy.rebuild_host_command("root@overlord", "/etc/nixos", [])

    assert command =~
             "'ssh' '-o' 'BatchMode=yes' '-o' 'StrictHostKeyChecking=accept-new' '--' 'root@overlord'"

    assert command =~ "'-I'"
    assert command =~ "'nixos-config=/etc/nixos/configuration.nix'"
  end

  test "deploy commands reject unsafe remote inputs" do
    assert_raise ArgumentError, ~r/absolute path/, fn ->
      NixSwarm.Deploy.sync_command("/tmp/nix-swarm", "root@nixos-2", "relative/path")
    end

    assert_raise ArgumentError, ~r/must not contain '\.\.'/, fn ->
      NixSwarm.Deploy.rebuild_host_command("root@nixos-2", "/etc/../tmp", [])
    end

    assert_raise ArgumentError, ~r/unsupported whitespace/, fn ->
      NixSwarm.Deploy.sync_command("/tmp/nix-swarm", "root@nixos-2 bad", "/etc/nixos/nix-swarm")
    end
  end

  test "validation commands evaluate machine modules through nixos eval-config" do
    commands = NixSwarm.Deploy.validation_commands(["/tmp/nix-swarm/machines/nixos-2.nix"])

    assert commands == [
             "nix-instantiate --eval --strict --expr 'let eval = import <nixpkgs/nixos/lib/eval-config.nix> {\n  system = builtins.currentSystem;\n  modules = [ (builtins.toPath \"/tmp/nix-swarm/machines/nixos-2.nix\") ];\n  specialArgs = { inputs = {}; };\n}; in {\n  node = eval.config.services.nix-swarm.nodeName;\n  peers = eval.config.services.nix-swarm.peers;\n  services = builtins.attrNames eval.config.services.nix-swarm.services;\n  ingress = builtins.attrNames eval.config.services.nix-swarm.ingress.sites;\n}'"
           ]
  end

  test "plan builds dry-run result commands per host" do
    source = Path.expand("..", __DIR__)
    plan = NixSwarm.Deploy.plan(hosts: "nixos-2,nixos-3", source: source, dry_run: true)

    assert plan.dry_run
    assert length(plan.validation.machine_files) >= 2
    assert Enum.any?(plan.validation.commands, &String.contains?(&1, "eval-config.nix"))
    assert Enum.map(plan.results, & &1.host) == ["nixos-2", "nixos-3"]
    assert Enum.all?(plan.results, &String.contains?(&1.sync_command, "/etc/nixos/nix-swarm"))
    assert Enum.all?(plan.results, &String.contains?(&1.rebuild_command, "nixos-rebuild"))
  end

  test "plan targets all machine files by default" do
    source = Path.expand("..", __DIR__)
    plan = NixSwarm.Deploy.plan(source: source)

    assert Enum.map(plan.results, & &1.host) == ["example-node-a", "example-node-b"]
  end

  test "plan accepts defaults maps for update flows" do
    source = Path.expand("..", __DIR__)
    plan = NixSwarm.Deploy.plan(NixSwarm.Deploy.defaults(source))

    assert plan.source == source
    assert Enum.map(plan.results, & &1.host) == ["example-node-a", "example-node-b"]
  end
end
