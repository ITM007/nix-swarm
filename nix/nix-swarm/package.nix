{ pkgs }:

(import ./packages.nix { inherit pkgs; }).combined
