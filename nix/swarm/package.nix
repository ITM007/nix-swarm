{ pkgs }:

let
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ../..;
    filter = path: type:
      let
        base = builtins.baseNameOf path;
      in
      !(base == ".git" || base == "_build" || base == "deps" || base == ".serena");
  };

  release = pkgs.beamPackages.mixRelease {
    pname = "swarm";
    inherit version src;
    mixEnv = "prod";
  };

  cliWrapper = pkgs.writeShellScript "swarm" ''
    default_cookie_file=/etc/nixos/nix-swarm/secrets/swarm.cookie

    if [ -z "''${SWARM_COOKIE:-}" ] && [ -z "''${SWARM_COOKIE_FILE:-}" ] && [ -r "$default_cookie_file" ]; then
      export SWARM_COOKIE_FILE="$default_cookie_file"
    fi

    if [ -n "''${SWARM_COOKIE:-}" ]; then
      export RELEASE_COOKIE="$SWARM_COOKIE"
    elif [ -n "''${SWARM_COOKIE_FILE:-}" ] && [ -r "$SWARM_COOKIE_FILE" ]; then
      export RELEASE_COOKIE="$(${pkgs.coreutils}/bin/tr -d '\n' < "$SWARM_COOKIE_FILE")"
    else
      export RELEASE_COOKIE="swarm-local-cli"
    fi

    exec ${release}/bin/swarm eval 'Swarm.CLI.main(System.argv() |> Enum.reject(&(&1 == "--")))' -- "$@"
  '';
in
pkgs.runCommand "swarm-${version}" {} ''
  mkdir -p "$out/bin"

  for path in ${release}/*; do
    base="$(basename "$path")"

    if [ "$base" != "bin" ]; then
      ln -s "$path" "$out/$base"
    fi
  done

  ln -s ${release}/bin/swarm "$out/bin/swarmd"
  install -Dm755 ${cliWrapper} "$out/bin/swarm"
''
