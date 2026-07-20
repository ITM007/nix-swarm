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

For multiple nodes, duplicate the machine output and metadata, use resolvable BEAM node names, and allow ports 4369/4370 only on a private overlay interface.
