#!/usr/bin/env nu

# Run the Phoenix UI directly against the Overlord query socket.

def env-or [name: string, fallback: string] {
  let value = ($env | get --optional $name)
  if $value == null or $value == "" { $fallback } else { $value }
}

def fail [message: string] {
  error make { msg: $message }
}

def check-user-systemd [] {
  let result = (^nix develop --command systemctl --user show-environment | complete)
  if $result.exit_code != 0 {
    fail "The systemd user manager is unavailable; start a user session first"
  }
}

def unit-state [unit: string] {
  let result = (^nix develop --command systemctl --user show --property=ActiveState --value $unit | complete)
  if $result.exit_code != 0 { "inactive" } else { $result.stdout | str trim }
}

def unit-running [unit: string] {
  (unit-state $unit) in ["active", "activating", "reloading"]
}

def unit-log [unit: string] {
  let result = (^nix develop --command journalctl --user --unit $unit --no-pager --lines 40 | complete)
  if $result.exit_code == 0 and ($result.stdout | str trim) != "" {
    $result.stdout
  } else {
    "(no journal output was available)"
  }
}

def stop-unit [label: string, unit: string] {
  if (unit-state $unit) == "inactive" { return }
  print $"Stopping ($label) ($unit)..."
  ^nix develop --command systemctl --user stop $unit | complete
  ^nix develop --command systemctl --user reset-failed $unit | complete
}

def wait-for-socket [socket: string, unit: string] {
  for _ in 1..40 {
    if ($socket | path exists) { return }
    if not (unit-running $unit) {
      fail $"The SSH query tunnel stopped:\nunit=($unit), state=(unit-state $unit)\n(unit-log $unit)"
    }
    sleep 500ms
  }
  fail $"Timed out waiting for the forwarded query socket: ($socket)\n(unit-log $unit)"
}

def wait-for-web [port: int, unit: string] {
  let url = $"http://127.0.0.1:($port)/healthz"
  for _ in 1..120 {
    try {
      let _response = (http get $url)
      return
    } catch { |_error| }

    if not (unit-running $unit) {
      fail $"Phoenix stopped before becoming ready:\nunit=($unit), state=(unit-state $unit)\n(unit-log $unit)"
    }
    sleep 500ms
  }
  fail $"Timed out waiting for Phoenix at ($url):\n(unit-log $unit)"
}

def start-tunnel [root: string, runtime: string, unit: string] {
  let socket = ($runtime | path join "query.sock")
  if ($socket | path exists) { rm -f $socket }

  stop-unit "query tunnel" $unit
  let forward = $"($socket):/run/nix-swarm/query.sock"
  let result = (^nix develop --command systemd-run --user
    $"--unit=($unit)"
    "--collect"
    "--property=Restart=on-failure"
    "--property=RestartSec=2s"
    "--property=KillMode=control-group"
    $"--working-directory=($root)"
    "nix" "develop" "--command" "ssh" "-N" "-T"
    "-o" "BatchMode=yes"
    "-o" "ConnectTimeout=10"
    "-o" "ExitOnForwardFailure=yes"
    "-o" "ForwardAgent=no"
    "-o" "IdentitiesOnly=yes"
    "-o" "StrictHostKeyChecking=yes"
    "-o" "StreamLocalBindUnlink=yes"
    "-L" $forward
    "root@overlord" | complete)
  if $result.exit_code != 0 { fail $"Could not start the Overlord query tunnel: ($result.stderr)" }
  wait-for-socket $socket $unit
  $socket
}

def prepare-web [root: string, web_root: string] {
  let deps = (^nix develop $root "--command" "bash" "-c" 'cd "$1" && exec mix deps.get' "bash" $web_root | complete)
  if $deps.exit_code != 0 { fail $"Could not prepare Phoenix dependencies: ($deps.stderr)" }

  let phoenix_esm = ($web_root | path join "deps" "phoenix" "priv" "static" "phoenix.mjs")
  let liveview_esm = ($web_root | path join "deps" "phoenix_live_view" "priv" "static" "phoenix_live_view.esm.js")
  let assets = (^nix develop $root "--command" "bash" "-c" 'cd "$1" && set -e && mkdir -p priv/static/assets && esbuild assets/js/app.js --bundle --minify --target=es2017 "--alias:phoenix=$2" "--alias:phoenix_live_view=$3" --outdir=priv/static/assets && NODE_PATH="$1/deps:$1/_build/dev/lib" tailwindcss --input assets/css/app.css --output priv/static/assets/app.css --minify' "bash" $web_root $phoenix_esm $liveview_esm | complete)
  if $assets.exit_code != 0 { fail $"Could not build Phoenix assets: ($assets.stderr)" }
}

def start-web [root: string, web_root: string, runtime: string, socket: string, port: int, unit: string, config_source: string] {
  let secret_file = ($runtime | path join "secret-key-base")
  if not ($secret_file | path exists) {
    let secret = (^nix develop --command openssl rand -hex 64 | str trim)
    $secret | save --force $secret_file
    ^chmod 600 $secret_file
  }

  stop-unit "Phoenix" $unit
  prepare-web $root $web_root

  let result = (^nix develop --command systemd-run --user
    $"--unit=($unit)"
    "--collect"
    "--property=Restart=on-failure"
    "--property=RestartSec=2s"
    "--property=StartLimitBurst=3"
    "--property=StartLimitIntervalSec=30s"
    "--property=KillMode=control-group"
    $"--working-directory=($web_root)"
    "--setenv=MIX_ENV=prod"
    "--setenv=PHX_SERVER=true"
    $"--setenv=PORT=($port)"
    $"--setenv=NIX_SWARM_QUERY_SOCKET=($socket)"
    $"--setenv=SECRET_KEY_BASE_FILE=($secret_file)"
    $"--setenv=NIX_SWARM_CONFIG_SOURCE=($config_source)"
    "nix" "develop" $root "--command" "mix" "run" "--no-halt" | complete)
  if $result.exit_code != 0 { fail $"Could not start Phoenix: ($result.stderr)" }
  wait-for-web $port $unit
}

def usage [] {
  print $'Usage: nu test.nu [command]

Commands:
  up       Start Phoenix against Overlord by default
  down     Stop Phoenix and the SSH query tunnel
  status   Show Phoenix and tunnel status
  logs     Follow Phoenix and tunnel logs
  reset    Stop the test environment and remove its runtime files
  open     Open the web app in the default browser

URL: http://nix-swarm-dev.localhost:4100/
Config browser source: /home/itm/.config/nix-swarm
'
}

def main [action: string = "up"] {
  let root = ($env.FILE_PWD | path expand)
  let web_root = ($root | path join "nix-swarm-web")
  let config_source = (env-or "NIX_SWARM_CONFIG_SOURCE" "/home/itm/.config/nix-swarm")
  let user_runtime = (env-or "XDG_RUNTIME_DIR" "")
  let port = 4100
  let url = $"http://nix-swarm-dev.localhost:($port)/"
  let runtime = ($user_runtime | path join "nix-swarm-web-test")
  let web_unit = "nix-swarm-web-test.service"
  let tunnel_unit = "nix-swarm-web-test-tunnel.service"

  if $action in ["help", "--help", "-h"] {
    usage
    return
  }

  if $action == "open" {
    ^xdg-open $url | complete | ignore
    return
  }

  if $user_runtime == "" { fail "XDG_RUNTIME_DIR is required" }
  if not ($config_source | path exists) { fail $"Config source does not exist: ($config_source)" }
  check-user-systemd
  mkdir $runtime

  match $action {
    "up" => {
      let socket = (start-tunnel $root $runtime $tunnel_unit)
      try {
        start-web $root $web_root $runtime $socket $port $web_unit $config_source
        print $"Open this URL in your browser: ($url)"
      } catch { |caught|
        stop-unit "Phoenix" $web_unit
        stop-unit "query tunnel" $tunnel_unit
        error make { msg: $"Startup failed; services were stopped: ($caught)" }
      }
    }
    "down" => {
      stop-unit "Phoenix" $web_unit
      stop-unit "query tunnel" $tunnel_unit
      let socket = ($runtime | path join "query.sock")
      if ($socket | path exists) { rm -f $socket }
      print "Web test environment is down."
    }
    "status" => {
      print $"Phoenix: (unit-state $web_unit); query tunnel: (unit-state $tunnel_unit)"
      print $"Open this URL in your browser: ($url)"
    }
    "logs" => {
      ^nix develop --command journalctl --user --unit $web_unit --unit $tunnel_unit --follow --lines 100
    }
    "reset" => {
      stop-unit "Phoenix" $web_unit
      stop-unit "query tunnel" $tunnel_unit
      rm -rf $runtime
      print "Web test environment and runtime files were reset."
    }
    _ => {
      usage
      fail $"Unknown command: ($action)"
    }
  }
}