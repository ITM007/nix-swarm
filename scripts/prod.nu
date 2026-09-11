#!/usr/bin/env nu

# Connect the Phoenix UI to the production Nix-Swarm cluster through Overlord.
# test.nu owns the verified SSH-tunnel and Phoenix lifecycle implementation.

def main [action: string = "up"] {
  if $action in ["help", "--help", "-h"] {
    print $'Usage: nu scripts/prod.nu [command]

Commands:
  up       Connect Phoenix to the production cluster through Overlord
  down     Stop Phoenix and the production SSH query tunnel
  status   Show Phoenix and tunnel status
  logs     Follow Phoenix and tunnel logs
  reset    Stop the production UI and remove its runtime files

URL: http://nix-swarm-dev.localhost:4100/
'
    return
  }

  let root = ($env.FILE_PWD | path join ".." | path expand)
  let launcher = ($root | path join "test.nu")
  ^nu $launcher $action
}

main
