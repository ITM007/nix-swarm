{ ... }:
throw ''
  Replace machines/hardware-configuration.nix with the target's real hardware config:
    ssh root@node-a nixos-generate-config --show-hardware-config > machines/hardware-configuration.nix
''
