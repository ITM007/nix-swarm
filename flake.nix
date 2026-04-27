{
  description = "Nix-Swarm leaderless NixOS cluster runtime";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f system (import nixpkgs { inherit system; })
        );
    in
    {
      packages = forAllSystems (_system: pkgs: let
        nixSwarm = import ./nix/nix-swarm/package.nix { inherit pkgs; };
      in {
        nix-swarm = nixSwarm;
        default = nixSwarm;
      });

      devShells = forAllSystems (_system: pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ elixir erlang rebar3 git ];
        };
      });

      nixosModules = {
        nix-swarm = import ./nix/nix-swarm/module.nix;
        default = self.nixosModules.nix-swarm;
      };
    };
}
