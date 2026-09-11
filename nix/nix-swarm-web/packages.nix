{ pkgs }:

let
  lib = pkgs.lib;
  beamPackages = pkgs.beamPackages.extend (_final: previous: {
    elixir = previous.elixir_1_20;
  });
  version = lib.strings.removeSuffix "\n" (builtins.readFile ../../VERSION);
  webRoot = ../../nix-swarm-web;
  daisyui = pkgs.fetchFromGitHub {
    owner = "saadeghi";
    repo = "daisyui";
    rev = "22ecff57f2c391b80a75617325748cf4d13fdf47";
    hash = "sha256-I2LI9VYVxQcvoMDgDWmvNyQToS1rFm12V167YxqDs24=";
  };
  daisyuiNodePath = pkgs.runCommand "daisyui-node-path" { } ''
    mkdir -p "$out/daisyui/packages/bundle"
    cp -r ${daisyui}/packages/bundle/. "$out/daisyui/packages/bundle/"
  '';
  webReleaseAvailable =
    builtins.pathExists (webRoot + "/mix.exs")
    && builtins.pathExists (webRoot + "/mix.lock");

  release =
    if webReleaseAvailable then
      let
        src = lib.cleanSourceWith {
          src = webRoot;
          filter = path: _type:
            !(lib.elem (baseNameOf path) [
              "_build"
              "cover"
              "deps"
              ".elixir_ls"
            ]);
        };
        mixFodDeps = beamPackages.fetchMixDeps {
          pname = "nix-swarm-web-deps";
          inherit version src;
          hash = "sha256-1ucEPAUR20wRJi0h/ZoRA7P2z6BYedJBC6/vlDK2VtE=";
        };
      in
      (beamPackages.mixRelease {
        pname = "nix-swarm-web";
        inherit version src mixFodDeps;
        mixEnv = "prod";
      }).overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.esbuild pkgs.tailwindcss_4 ];
        postBuild = (old.postBuild or "") + ''
          mkdir -p priv/static/assets
          esbuild assets/js/app.js --bundle --minify --target=es2017 \
            --alias:phoenix=$PWD/deps/phoenix/priv/static/phoenix.mjs \
            --alias:phoenix_live_view=$PWD/deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js \
            --outdir=priv/static/assets
          NODE_PATH="$PWD/deps:$PWD/_build/prod/lib:/build/deps:${daisyuiNodePath}" tailwindcss \
            --input assets/css/app.css \
            --output priv/static/assets/app.css \
            --minify
        '';
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
      let
        releaseLauncher = pkgs.writeShellScript "nix-swarm-web-launcher" ''
          # This is a non-secret local release sentinel. The web release never
          # joins Erlang distribution and never receives the Nix-Swarm cookie.
          export RELEASE_COOKIE=nix-swarm-web-release
          export RELEASE_DISTRIBUTION=none
          exec ${release}/bin/nix_swarm_web "$@"
        '';
      in
      pkgs.runCommand "nix-swarm-web-${version}"
        {
          passthru.webReleaseAvailable = true;
        } ''
        mkdir -p "$out/bin"
        install -Dm755 ${releaseLauncher} "$out/bin/nix_swarm_web"
        ln -s nix_swarm_web "$out/bin/nix-swarm-web"
      '';
in
{
  nix-swarm-web = package;
}
