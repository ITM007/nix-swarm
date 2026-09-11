#!/usr/bin/env nu

# Start a live three-node Docker cluster and the local Phoenix server.
# The web process reaches node-a through an SSH stream-local socket forward.

def env-or [name: string, fallback: string] {
  let value = ($env | get --optional $name)
  if $value == null or $value == "" { $fallback } else { $value }
}

def fail [message: string] {
  error make { msg: $message }
}

def configured-port [name: string, fallback: string] {
  let raw = (env-or $name $fallback)
  let port = ($raw | into int)
  if $port < 1 or $port > 65535 {
    fail $"($name) must be between 1 and 65535"
  }
  $port
}

def configured-browser-host [name: string, fallback: string] {
  let host = (env-or $name $fallback | str trim)
  let comparison = ($host | str downcase)
  if $comparison in ["", "localhost", "127.0.0.1", "::1", "[::1]"] {
    fail $"($name) must use a separate browser hostname such as nix-swarm-dev.localhost; this prevents overwriting another localhost session"
  }
  $host
}

def stack [root: string, action: string] {
  ^nix develop --command $"($root)/scripts/docker-stack" $action
}

def check-user-systemd [] {
  let result = (^nix develop --command systemctl --user show-environment | complete)
  if $result.exit_code != 0 {
    fail "The systemd user manager is unavailable; start a user session with systemd before using the dev environment"
  }
}

def unit-state [unit: string] {
  let result = (^nix develop --command systemctl --user show --property=ActiveState --value $unit | complete)
  if $result.exit_code != 0 { "inactive" } else { $result.stdout | str trim }
}

def unit-starting [unit: string] {
  (unit-state $unit) in ["active", "activating", "reloading"]
}

def stop-unit [label: string, unit: string] {
  if (unit-state $unit) == "inactive" { return }
  print $"Stopping ($label) ($unit)..."
  ^nix develop --command systemctl --user stop $unit | complete
  ^nix develop --command systemctl --user reset-failed $unit | complete
}

def unit-log [unit: string] {
  let result = (^nix develop --command journalctl --user --unit $unit --no-pager --lines 40 | complete)
  if $result.exit_code == 0 and ($result.stdout | str trim) != "" {
    $result.stdout
  } else {
    "(no journal output was available)"
  }
}

def wait-for-tunnel [socket: string, unit: string] {
  for _ in 1..60 {
    if ($socket | path exists) { return }
    if not (unit-starting $unit) {
      let state = (unit-state $unit)
      let log = (unit-log $unit)
      fail $"The query tunnel exited before becoming ready:\nunit=($unit), state=($state)\nunit log:\n($log)"
    }
    sleep 500ms
  }
  let log = (unit-log $unit)
  fail $"Timed out waiting for the forwarded query socket: ($socket)\nunit log:\n($log)"
}

def wait-for-web [port: int, unit: string] {
  let url = $"http://127.0.0.1:($port)/healthz"
  for _ in 1..120 {
    try {
      let _response = (http get $url)
      return
    } catch { |_error| }

    if not (unit-starting $unit) {
      let state = (unit-state $unit)
      let log = (unit-log $unit)
      fail $"Phoenix server exited before becoming ready:\nunit=($unit), state=($state)\nunit log:\n($log)"
    }
    sleep 500ms
  }
  let log = (unit-log $unit)
  fail $"Timed out waiting for Phoenix at ($url):\nunit log:\n($log)"
}

def start-tunnel [root: string, runtime: string, ssh_key: string, known_hosts: string, ssh_port: int, unit: string] {
  let socket = ($runtime | path join "query.sock")

  if ($socket | path exists) { rm -f $socket }

  ^nix develop --command systemctl --user stop $unit | complete
  ^nix develop --command systemctl --user reset-failed $unit | complete

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
    "-o" "ServerAliveInterval=10"
    "-o" "ServerAliveCountMax=3"
    "-o" "StrictHostKeyChecking=yes"
    "-o" "StreamLocalBindUnlink=yes"
    "-o" $"UserKnownHostsFile=($known_hosts)"
    "-i" $ssh_key
    "-p" ($ssh_port | into string)
    "-L" $forward
    "root@127.0.0.1" | complete)
  if $result.exit_code != 0 { fail $"Could not start the query tunnel: ($result.stderr)" }
  wait-for-tunnel $socket $unit
  $socket
}

def start-web [root: string, runtime: string, query_socket: string, port: int, unit: string, config_source: string] {
  let secret_file = ($runtime | path join "secret-key-base")
  let web_root = ($root | path join "nix-swarm-web")

  if not ($secret_file | path exists) {
    let secret = (^nix develop --command openssl rand -hex 64 | str trim)
    $secret | save --force $secret_file
    ^chmod 600 $secret_file
  }

  ^nix develop --command systemctl --user stop $unit | complete
  ^nix develop --command systemctl --user reset-failed $unit | complete

  let config_env_args = (if $config_source == "" { [] } else { [$"--setenv=NIX_SWARM_CONFIG_SOURCE=($config_source)"] })

  let deps = (^nix develop $root "--command" "bash" "-c" 'cd "$1" && exec mix deps.get' "bash" $web_root | complete)
  if $deps.exit_code != 0 {
    fail $"Could not prepare Phoenix dependencies: ($deps.stderr)"
  }

  # Build the static assets (css/js) into priv/static/assets. In MIX_ENV=prod there
  # is no asset watcher, so without this step /assets/* 404 and the page renders
  # unstyled with no LiveView client.
  let phoenix_esm = ($web_root | path join "deps" "phoenix" "priv" "static" "phoenix.mjs")
  let liveview_esm = ($web_root | path join "deps" "phoenix_live_view" "priv" "static" "phoenix_live_view.esm.js")
  let assets = (^nix develop $root "--command" "bash" "-c" 'cd "$1" && set -e && mkdir -p priv/static/assets && esbuild assets/js/app.js --bundle --minify --target=es2017 "--alias:phoenix=$2" "--alias:phoenix_live_view=$3" --outdir=priv/static/assets && NODE_PATH="$1/deps:$1/_build/dev/lib" tailwindcss --input assets/css/app.css --output priv/static/assets/app.css --minify' "bash" $web_root $phoenix_esm $liveview_esm | complete)
  if $assets.exit_code != 0 {
    fail $"Could not build Phoenix assets: ($assets.stderr)"
  }

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
    $"--setenv=NIX_SWARM_QUERY_SOCKET=($query_socket)"
    $"--setenv=SECRET_KEY_BASE_FILE=($secret_file)"
    ...$config_env_args
    "nix" "develop" $root "--command" "mix" "phx.server" | complete)
  if $result.exit_code != 0 { fail $"Could not start Phoenix: ($result.stderr)" }
  wait-for-web $port $unit
}

def usage [] {
  print $'Usage: scripts/dev.nu <command>

Commands:
  up       Build/start the three-node Docker cluster and Phoenix web server; default command
  down     Stop Phoenix, close the query tunnel, and stop the Docker cluster
  reset    Down plus remove the harness state volumes and generated secrets
  status   Show cluster status and local process status
  logs     Follow Phoenix and query-tunnel logs from systemd

Open this URL in your browser: http://nix-swarm-dev.localhost:4100/ after `up`.

Optional environment:
  NIX_SWARM_DOCKER_PROFILE       standard or hardened; default standard
  NIX_SWARM_DOCKER_PROJECT       Docker project name; default nix-swarm-dev
  NIX_SWARM_DOCKER_SSH_PORT      host SSH port for node-a; default 2221
  NIX_SWARM_DEV_WEB_HOST         browser hostname; default nix-swarm-dev.localhost
  NIX_SWARM_DEV_WEB_PORT         local Phoenix port; default 4100
  NIX_SWARM_CONFIG_SOURCE        optional Nix source directory shown read-only in the web sidebar; forwarded to Phoenix when set
'
}

def main [action: string = "up"] {
  if $action in ["help", "--help", "-h"] {
    usage
    return
  }

  let root = ($env.FILE_PWD | path join ".." | path expand)
  let raw_project = (env-or "NIX_SWARM_DOCKER_PROJECT" "nix-swarm-dev")
  let project = ($raw_project | str replace --all --regex "[^A-Za-z0-9_.-]" "-")
  let project = if $project in ["", ".", ".."] { "nix-swarm-dev" } else { $project }
  let ssh_port = (configured-port "NIX_SWARM_DOCKER_SSH_PORT" "2221")
  let web_host = (configured-browser-host "NIX_SWARM_DEV_WEB_HOST" "nix-swarm-dev.localhost")
  let web_port = (configured-port "NIX_SWARM_DEV_WEB_PORT" "4100")
  let config_source = (env-or "NIX_SWARM_CONFIG_SOURCE" "")
  let user_runtime = (env-or "XDG_RUNTIME_DIR" "")
  if $user_runtime == "" {
    fail "XDG_RUNTIME_DIR is required for isolated development sockets"
  }
  let runtime = ($user_runtime | path join "nix-swarm-dev" $project)
  let docker_secrets = ($root | path join "_build" "docker-secrets" $project)
  let web_unit = $"nix-swarm-dev-($project)-web.service"
  let tunnel_unit = $"nix-swarm-dev-($project)-tunnel.service"

  $env.NIX_SWARM_DOCKER_PROJECT = $project
  $env.NIX_SWARM_DOCKER_SSH_PORT = ($ssh_port | into string)

  match $action {
    "up" => {
      check-user-systemd
      mkdir $runtime
      if (unit-starting $web_unit) or (unit-starting $tunnel_unit) {
        fail $"The dev environment already has a live systemd user unit; run `scripts/dev.nu down` first"
      }

      try {
        print $"Open this URL in your browser: http://($web_host):($web_port)/"
        stack $root "up"
        let ssh_key = ($docker_secrets | path join "id_ed25519")
        if not ($ssh_key | path exists) {
          fail $"Docker stack did not create its operator key: ($ssh_key)"
        }

        let known_hosts = ($runtime | path join "known_hosts")
        let scan = (^nix develop --command ssh-keyscan -T 5 -p $ssh_port 127.0.0.1 | complete)
        if $scan.exit_code != 0 or ($scan.stdout | str trim) == "" {
          fail $"Could not collect node-a SSH host key: ($scan.stderr)"
        }
        $scan.stdout | save --force $known_hosts
        ^chmod 600 $known_hosts

        let query_socket = (start-tunnel $root $runtime $ssh_key $known_hosts $ssh_port $tunnel_unit)
        start-web $root $runtime $query_socket $web_port $web_unit $config_source

        print $"Open this URL in your browser: http://($web_host):($web_port)/"
        print $"Phoenix unit: ($web_unit)"
        print $"Query tunnel unit: ($tunnel_unit)"
      } catch { |caught|
        stop-unit "Phoenix" $web_unit
        stop-unit "query tunnel" $tunnel_unit
        let query_socket = ($runtime | path join "query.sock")
        if ($query_socket | path exists) { rm -f $query_socket }
        try { stack $root "down" } catch { |_cleanup_error| }
        if ($runtime | path exists) { rm -rf $runtime }
        error make { msg: $"Dev environment startup failed and was cleaned up: ($caught)" }
      }
    }
    "down" => {
      check-user-systemd
      stop-unit "Phoenix" $web_unit
      stop-unit "query tunnel" $tunnel_unit
      let query_socket = ($runtime | path join "query.sock")
      if ($query_socket | path exists) { rm -f $query_socket }
      stack $root "down"
      if ($runtime | path exists) { rm -rf $runtime }
      print "Dev environment is down; named cluster state volumes were preserved."
    }
    "reset" => {
      check-user-systemd
      stop-unit "Phoenix" $web_unit
      stop-unit "query tunnel" $tunnel_unit
      stack $root "reset"
      rm -rf $runtime
      print "Dev environment and harness-owned state were reset."
    }
    "status" => {
      check-user-systemd
      stack $root "status"
      let web = (unit-state $web_unit)
      let tunnel = (unit-state $tunnel_unit)
      print $"Phoenix: ($web); query tunnel: ($tunnel)"
      print $"Open this URL in your browser: http://($web_host):($web_port)/"
    }
    "logs" => {
      check-user-systemd
      ^nix develop --command journalctl --user --unit $web_unit --unit $tunnel_unit --follow --lines 100
    }
    _ => {
      usage
      fail $"Unknown command: ($action)"
    }
  }
}
