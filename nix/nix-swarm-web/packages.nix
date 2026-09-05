{ pkgs }:

let
  lib = pkgs.lib;
  beamPackages = pkgs.beamPackages.extend (_final: previous: {
    elixir = previous.elixir_1_20;
  });
  version = lib.strings.removeSuffix "\n" (builtins.readFile ../../VERSION);
  webRoot = ../../nix-swarm-web;
  webReleaseAvailable =
    builtins.pathExists (webRoot + "/mix.exs")
    && builtins.pathExists (webRoot + "/mix.lock");

  release =
    if webReleaseAvailable then
      let
        src = lib.fileset.toSource {
          root = ../..;
          fileset = webRoot;
        };
        mixFodDeps = beamPackages.fetchMixDeps {
          pname = "nix-swarm-web-deps";
          inherit version src;
          # The web application is intentionally not part of this phase. Replace
          # this with the fixed-output hash when its lockfile is introduced.
          hash = lib.fakeHash;
        };
      in
      (beamPackages.mixRelease {
        pname = "nix-swarm-web";
        inherit version src mixFodDeps;
        mixEnv = "prod";
      }).overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.esbuild ];
      })
    else
      null;

  unavailablePackage = pkgs.stdenv.mkDerivation {
    pname = "nix-swarm-web";
    inherit version;
    dontUnpack = true;
    passthru.webReleaseAvailable = false;
    installPhase = ''
      echo "nix-swarm-web source is not present; add the nested Mix release before building this package" >&2
      exit 1
    '';
  };

  package =
    if release == null then
      unavailablePackage
    else
      pkgs.runCommand "nix-swarm-web-${version}"
        {
          passthru.webReleaseAvailable = true;
        } ''
        mkdir -p "$out"
        cp -a ${release}/. "$out/"
        test -x "$out/bin/nix_swarm_web"
        ln -s nix_swarm_web "$out/bin/nix-swarm-web"
      '';
in
{
  nix-swarm-web = package;
}
