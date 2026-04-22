let
  pkgs = import <nixpkgs> { };
in
import ./nix/package.nix { inherit pkgs; }
