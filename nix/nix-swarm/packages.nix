{ pkgs, usePrebuiltNifs ? true }:
let
  lib = pkgs.lib;
  beamPackages = pkgs.beamPackages.extend (_final: previous: {
    elixir = previous.elixir_1_20;
  });
  version = lib.strings.removeSuffix "\n" (builtins.readFile ../../VERSION);
  nifTarget =
    if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then
      "aarch64-unknown-linux-gnu"
    else
      "x86_64-unknown-linux-gnu";

  mixDepsHash =
    if lib.versionAtLeast beamPackages.elixir.version "1.18.0" then
      "sha256-/kSIAgMjYEcTXms0dd6iCGnMswdrK8IVknhwL19E5lg="
    else
      "sha256-vywmOaqNrGlWeE3itE85MDufVVhITz3xZmWo68rnmj4=";

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../lib
      ../../mix.exs
      ../../mix.lock
      ../../VERSION
    ];
  };

  starterConfig = lib.fileset.toSource {
    root = ../../examples/starter;
    fileset = ../../examples/starter;
  };

  mixFodDeps =
    (beamPackages.fetchMixDeps {
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
          "libex_ratatui-v0.11.1-nif-2.16-${nifTarget}.so.tar.gz"
          "libex_ratatui-v0.11.1-nif-2.17-${nifTarget}.so.tar.gz"
        ];

        artifactHashes =
          if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then
            [
              "sha256-0SmRgwrYhaDD49zV0dfTTh74ip8gqqeSQT81uphd0zw="
              "sha256-BgU7vyEWn7/gF9vBGTdrkxRBCL4SvKz3gzqEEIlFGoA="
            ]
          else
            [
              "sha256-iDPYcEke1dboz2HkUQBbntn/e/Z/F5L7zzjywAnjWtM="
              "sha256-7VSGObPnmSmiIF7PkqGg/s0hN9/G4bpcaaNA3WpP90E="
            ];

        artifacts = [
          (pkgs.fetchurl {
            url = "https://github.com/mcass19/ex_ratatui/releases/download/v0.11.1/${builtins.elemAt fileNames 0}";
            hash = builtins.elemAt artifactHashes 0;
          })
          (pkgs.fetchurl {
            url = "https://github.com/mcass19/ex_ratatui/releases/download/v0.11.1/${builtins.elemAt fileNames 1}";
            hash = builtins.elemAt artifactHashes 1;
          })
        ];
      in
      pkgs.runCommand "ex-ratatui-precompiled-nif-cache" { } ''
        mkdir -p "$out"
        ln -s ${builtins.elemAt artifacts 0} "$out/${builtins.elemAt fileNames 0}"
        ln -s ${builtins.elemAt artifacts 1} "$out/${builtins.elemAt fileNames 1}"
      ''
    else
      pkgs.runCommand "ex-ratatui-source-nif-cache" { } ''
        mkdir -p "$out"
        echo "NIF cache built from source — place compiled .so tarballs here" > "$out/README"
      '';

  release = (beamPackages.mixRelease {
    pname = "nix-swarm";
    inherit version src;
    mixEnv = "prod";
    inherit mixFodDeps;
  }).overrideAttrs
    (old: {
      RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = exRatatuiNifCache;
      ELIXIR_ERL_OPTIONS = "+fnu";
      postFixup = (old.postFixup or "") + ''
        # mixRelease normally places RELEASE_COOKIE on the ERTS command line.
        # Agents instead use a private HOME/.erlang.cookie so the credential
        # never appears in argv or the environment.
        for script in "$out/bin/nix_swarm" "$out/bin/.nix_swarm-wrapped"; do
          if [ -f "$script" ]; then
            sed -i '/--cookie "$RELEASE_COOKIE"/d' "$script"
            sed -i '/^RELEASE_COOKIE=/d' "$script"
          fi
        done
      '';
    });

  cliWrapper = pkgs.writeShellScript "swarm" ''
    template_root="$(cd "$(dirname "$0")/../share/nix-swarm/template" && pwd)"
    config_root="''${NIX_SWARM_SOURCE:-$HOME/.config/nix-swarm}"

    if [ ! -e "$config_root" ]; then
      mkdir -p "$(dirname "$config_root")"
      cp -a "$template_root" "$config_root"
    fi

    chmod -R u+w "$config_root"
    export NIX_SWARM_SOURCE="$config_root"
    export NIX_SWARM_ROLE=operator

    exec ${release}/bin/nix_swarm eval 'Application.ensure_all_started(:nix_swarm); NixSwarm.CLI.main(System.argv() |> Enum.reject(&(&1 == "--")))' -- "$@"
  '';

  daemonWrapper = pkgs.writeShellScript "nix-swarmd" ''
    export NIX_SWARM_ROLE=agent

    if [ ! -r "$HOME/.erlang.cookie" ]; then
      echo "nix-swarmd: private HOME/.erlang.cookie is required" >&2
      exit 1
    fi

    exec ${release}/bin/nix_swarm "$@"
  '';

  queryWrapper = pkgs.writeShellScript "nix-swarm-query" ''
    export NIX_SWARM_ROLE=operator
    exec ${release}/bin/nix_swarm eval 'Application.ensure_all_started(:nix_swarm); NixSwarm.QueryCLI.main(System.argv() |> Enum.reject(&(&1 == "--")))' -- "$@"
  '';

  mkPackage =
    { pname
    , includeOperator ? false
    , includeCluster ? false
    }:
    pkgs.runCommand "${pname}-${version}" { } ''
      mkdir -p "$out/bin"

      for path in ${release}/*; do
        base="$(basename "$path")"

        if [ "$base" != "bin" ]; then
          ln -s "$path" "$out/$base"
        fi
      done

      ${lib.optionalString includeOperator ''
        mkdir -p "$out/share/nix-swarm"
        cp -a ${starterConfig} "$out/share/nix-swarm/template"
        chmod -R u+w "$out/share/nix-swarm/template"
        install -Dm755 ${cliWrapper} "$out/bin/nix-swarm"
        ln -s nix-swarm "$out/bin/swarm"
      ''}

      ${lib.optionalString includeCluster ''
        install -Dm755 ${daemonWrapper} "$out/bin/nix-swarmd"
        install -Dm755 ${queryWrapper} "$out/bin/nix-swarm-query"
      ''}
    '';
in
assert lib.assertMsg
  (lib.versionAtLeast beamPackages.elixir.version "1.20.0")
  "Nix-Swarm requires Elixir 1.20 or newer for set-theoretic type inference";
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
