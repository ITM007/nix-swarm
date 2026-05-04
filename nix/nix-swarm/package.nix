{ pkgs }:

let
  version = "0.1.3";
  mixDepsHash =
    if pkgs.lib.versionAtLeast pkgs.elixir.version "1.18.0" then
      "sha256-1COSMxulZKTRsLbYEihvkoC+mtLN8fXPD9ubOZHVmX8="
    else
      "sha256-vywmOaqNrGlWeE3itE85MDufVVhITz3xZmWo68rnmj4=";
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
    let
      fileNames = [
        "libex_ratatui-v0.8.0-nif-2.16-x86_64-unknown-linux-gnu.so.tar.gz"
        "libex_ratatui-v0.8.0-nif-2.17-x86_64-unknown-linux-gnu.so.tar.gz"
      ];
      artifacts = [
        (pkgs.fetchurl {
          url = "https://github.com/mcass19/ex_ratatui/releases/download/v0.8.0/${builtins.elemAt fileNames 0}";
          hash = "sha256-f41G2I1+iXlRz1fbNKxf6WFSynKlAq8zL1Qw5/dUVa4=";
        })
        (pkgs.fetchurl {
          url = "https://github.com/mcass19/ex_ratatui/releases/download/v0.8.0/${builtins.elemAt fileNames 1}";
          hash = "sha256-XHHHvm7p3/A8gabr8RZh/QuYWM6pCKDg57BepCm0VGA=";
        })
      ];
    in
    pkgs.runCommand "ex-ratatui-precompiled-nif-cache" {} ''
      mkdir -p "$out"
      ln -s ${builtins.elemAt artifacts 0} "$out/${builtins.elemAt fileNames 0}"
      ln -s ${builtins.elemAt artifacts 1} "$out/${builtins.elemAt fileNames 1}"
    '';
  src = pkgs.lib.cleanSourceWith {
    src = ../..;
    filter = path: type:
      let
        base = builtins.baseNameOf path;
      in
      !(base == ".git" || base == "_build" || base == "deps" || base == ".serena");
  };

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
        echo "error: missing Nix-Swarm cookie; set NIX_SWARM_COOKIE_FILE or NIX_SWARM_COOKIE before launching $app_name" >&2
        exit 1
      fi
    }
  '';

  cliWrapper = pkgs.writeShellScript "swarm" ''
    template_root="$(cd "$(dirname "$0")/../share/nix-swarm/template" && pwd)"
    config_root="''${NIX_SWARM_SOURCE:-$HOME/.config/nix-swarm}"

    if [ ! -e "$config_root" ]; then
      mkdir -p "$(dirname "$config_root")"
      cp -a "$template_root" "$config_root"
    fi

    chmod -R u+w "$config_root"
    export NIX_SWARM_SOURCE="$config_root"

    exec ${release}/bin/nix_swarm eval 'NixSwarm.CLI.main(System.argv() |> Enum.reject(&(&1 == "--")))' -- "$@"
  '';

  daemonWrapper = pkgs.writeShellScript "nix-swarmd" ''
    ${cookieRuntimeSetup}
    resolve_cookie nix-swarmd
    exec ${release}/bin/nix_swarm "$@"
  '';
in
pkgs.runCommand "nix-swarm-${version}" {} ''
  mkdir -p "$out/bin"
  mkdir -p "$out/share/nix-swarm"

  for path in ${release}/*; do
    base="$(basename "$path")"

    if [ "$base" != "bin" ]; then
      ln -s "$path" "$out/$base"
    fi
  done

  cp -a ${src} "$out/share/nix-swarm/template"
  chmod -R u+w "$out/share/nix-swarm/template"
  cp -a "$out/share/nix-swarm/template/examples/config/cluster" "$out/share/nix-swarm/template/cluster"
  cp -a "$out/share/nix-swarm/template/examples/config/machines" "$out/share/nix-swarm/template/machines"
  install -Dm755 ${daemonWrapper} "$out/bin/nix-swarmd"
  install -Dm755 ${cliWrapper} "$out/bin/swarm"
  ln -s swarm "$out/bin/nix-swarm"
''
