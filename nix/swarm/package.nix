{ pkgs }:

let
  src = pkgs.lib.cleanSourceWith {
    src = ../..;
    filter = path: type:
      let
        base = builtins.baseNameOf path;
      in
      !(base == ".git" || base == "_build" || base == "deps" || base == ".serena");
  };
in
pkgs.beamPackages.mixRelease {
  pname = "swarm";
  version = "0.1.0";
  inherit src;
  mixEnv = "prod";
}
