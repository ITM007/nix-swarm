# Starter cluster

1. Replace `node-a`, `root@node-a`, and the system architecture where needed.
2. Capture hardware configuration:

   ```bash
   ssh root@node-a nixos-generate-config --show-hardware-config > machines/hardware-configuration.nix
   ```

3. Review `system.stateVersion`, then run `nix flake lock`.
4. Install the operator and initialize the node:

   ```bash
   nix profile add github:ITM007/nix-swarm#operator
   nix-swarm cluster plan --source .
   nix-swarm cluster init --source . --yes
   ```

5. Inspect it with `nix-swarm --source . --target nix-swarm@node-a`.

The flake exposes both `nixosConfigurations.node-a` and
`nixosConfigurations.node-a-hardened`. The normal deployment manifest points
to `node-a`; choose `node-a-hardened` in the manifest when you want the
hardened profile. Replace the hardened machine file's hostname, node name,
WireGuard interface, and deployment SSH key, then review every setting against
the target hardware. It intentionally does not configure WireGuard/Tailscale
or generate the Nix-Swarm cookie; provision those separately.

For multiple nodes, duplicate the machine output and metadata, use resolvable BEAM node names, and allow ports 4369/4370 only on a private overlay interface.
