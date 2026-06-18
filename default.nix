{ pkgs ? import <nixpkgs> { } }:
import ./nix/nix-swarm/packages.nix { inherit pkgs; }
