{ pkgs, usePrebuiltNifs ? true }:

let
  lib = pkgs.lib;
  version = "0.4.1";
  nifTarget =
    if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then
      "aarch64-unknown-linux-gnu"
    else
      "x86_64-unknown-linux-gnu";

  mixDepsHash =
    if lib.versionAtLeast pkgs.elixir.version "1.18.0" then
      "sha256-1COSMxulZKTRsLbYEihvkoC+mtLN8fXPD9ubOZHVmX8="
    else
      "sha256-vywmOaqNrGlWeE3itE85MDufVVhITz3xZmWo68rnmj4=";

  src = lib.cleanSourceWith {
    src = ../..;
    filter = path: _type:
      let
        base = builtins.baseNameOf path;
      in
      !(base == ".git" || base == "_build" || base == "deps" || base == ".serena");
  };

  mixFodDeps =
    (pkgs.beamPackages.fetchMixDeps {
      pname = "nix-swarm-deps";
      inherit version src;
      hash = mixDepsHash;
    }).overrideAttrs
      (_old: {
        ELIXIR_ERL_OPTIONS = "+fnu";
      });

  exRatatuiNifCache =
    if usePrebuiltNifs then
      let
        fileNames = [
          "libex_ratatui-v0.8.0-nif-2.16-${nifTarget}.so.tar.gz"
          "libex_ratatui-v0.8.0-nif-2.17-${nifTarget}.so.tar.gz"
        ];

        artifactHashes =
          if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then
            [
              "sha256-wNsrDx/P87+Rxv6tdouWKYEODFHxxdczfqHYzjjkU9U="
              "sha256-JFdLuoRnley1jomJSVaZbHZOuaFCfKtX5xbEDJbWmPA="
            ]
          else
            [
              "sha256-f41G2I1+iXlRz1fbNKxf6WFSynKlAq8zL1Qw5/dUVa4="
              "sha256-XHHHvm7p3/A8gabr8RZh/QuYWM6pCKDg57BepCm0VGA="
            ];

        artifacts = [
          (pkgs.fetchurl {
            url = "https://github.com/mcass19/ex_ratatui/releases/download/v0.8.0/${builtins.elemAt fileNames 0}";
            hash = builtins.elemAt artifactHashes 0;
          })
          (pkgs.fetchurl {
            url = "https://github.com/mcass19/ex_ratatui/releases/download/v0.8.0/${builtins.elemAt fileNames 1}";
            hash = builtins.elemAt artifactHashes 1;
          })
        ];
      in
      pkgs.runCommand "ex-ratatui-precompiled-nif-cache" {} ''
        mkdir -p "$out"
        ln -s ${builtins.elemAt artifacts 0} "$out/${builtins.elemAt fileNames 0}"
        ln -s ${builtins.elemAt artifacts 1} "$out/${builtins.elemAt fileNames 1}"
      ''
    else
      pkgs.runCommand "ex-ratatui-source-nif-cache" {} ''
        mkdir -p "$out"
        echo "NIF cache built from source — place compiled .so tarballs here" > "$out/README"
      '';

  release = (pkgs.beamPackages.mixRelease {
    pname = "nix-swarm";
    inherit version src;
    mixEnv = "prod";
    inherit mixFodDeps;
  }).overrideAttrs
    (_old: {
      RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = exRatatuiNifCache;
      ELIXIR_ERL_OPTIONS = "+fnu";
    });

  cookieRuntimeSetup = ''
    default_cookie_file=/etc/nixos/nix-swarm/secrets/nix-swarm.cookie
    config_root="''${NIX_SWARM_SOURCE:-$HOME/.config/nix-swarm}"

    resolve_cookie() {
      app_name="$1"
      shift

      if [ -z "''${NIX_SWARM_COOKIE:-}" ] && [ -z "''${NIX_SWARM_COOKIE_FILE:-}" ]; then
        for candidate in \
          "$config_root/secrets/nix-swarm.cookie" \
          "$config_root/secrets/swarm.cookie" \
          "$default_cookie_file"
        do
          if [ -r "$candidate" ]; then
            export NIX_SWARM_COOKIE_FILE="$candidate"
            break
          fi
        done
      fi

      if [ -n "''${NIX_SWARM_COOKIE:-}" ]; then
        export RELEASE_COOKIE="$NIX_SWARM_COOKIE"
      elif [ -n "''${NIX_SWARM_COOKIE_FILE:-}" ] && [ -r "$NIX_SWARM_COOKIE_FILE" ]; then
        export RELEASE_COOKIE="$(${pkgs.coreutils}/bin/tr -d '\n' < "$NIX_SWARM_COOKIE_FILE")"
      else
        export RELEASE_COOKIE="nix-swarm-local-placeholder"
      fi
    }
  '';

  cliWrapper = pkgs.writeShellScript "swarm" ''
    ${cookieRuntimeSetup}
    template_root="$(cd "$(dirname "$0")/../share/nix-swarm/template" && pwd)"
    config_root="''${NIX_SWARM_SOURCE:-$HOME/.config/nix-swarm}"

    if [ ! -e "$config_root" ]; then
      mkdir -p "$(dirname "$config_root")"
      cp -a "$template_root" "$config_root"
    fi

    chmod -R u+w "$config_root"
    export NIX_SWARM_SOURCE="$config_root"
    resolve_cookie nix-swarm "$@"

    # Fix distribution port so remote peers can connect back to the operator
    export ELIXIR_ERL_OPTIONS="-kernel inet_dist_listen_min 4370 -kernel inet_dist_listen_max 4370 ''${ELIXIR_ERL_OPTIONS:-}"

    exec ${release}/bin/nix_swarm eval 'NixSwarm.CLI.main(System.argv() |> Enum.reject(&(&1 == "--")))' -- "$@"
  '';

  daemonWrapper = pkgs.writeShellScript "nix-swarmd" ''
    ${cookieRuntimeSetup}
    resolve_cookie nix-swarmd
    exec ${release}/bin/nix_swarm "$@"
  '';

  mkPackage = {
    pname,
    includeOperator ? false,
    includeCluster ? false
  }:
    pkgs.runCommand "${pname}-${version}" {} ''
      mkdir -p "$out/bin"

      for path in ${release}/*; do
        base="$(basename "$path")"

        if [ "$base" != "bin" ]; then
          ln -s "$path" "$out/$base"
        fi
      done

      ${lib.optionalString includeOperator ''
        mkdir -p "$out/share/nix-swarm"
        cp -a ${src} "$out/share/nix-swarm/template"
        chmod -R u+w "$out/share/nix-swarm/template"
        cp -a "$out/share/nix-swarm/template/examples/config/cluster" "$out/share/nix-swarm/template/cluster"
        cp -a "$out/share/nix-swarm/template/examples/config/machines" "$out/share/nix-swarm/template/machines"
        install -Dm755 ${cliWrapper} "$out/bin/nix-swarm"
        ln -s nix-swarm "$out/bin/swarm"
      ''}

      ${lib.optionalString includeCluster ''
        install -Dm755 ${daemonWrapper} "$out/bin/nix-swarmd"
      ''}
    '';
in
{
  operator = mkPackage {
    pname = "nix-swarm-operator";
    includeOperator = true;
  };

  cluster = mkPackage {
    pname = "nix-swarm-cluster";
    includeCluster = true;
  };

  combined = mkPackage {
    pname = "nix-swarm";
    includeOperator = true;
    includeCluster = true;
  };
}
