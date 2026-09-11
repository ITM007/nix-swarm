import Config

# Optional operator-owned Nix source shown read-only in the map sidebar.
# Absent by default: the web service never receives a source-tree path unless
# the operator explicitly points NIX_SWARM_CONFIG_SOURCE at one.
config :nix_swarm_web,
  config_source: System.get_env("NIX_SWARM_CONFIG_SOURCE")

config :nix_swarm_web,
  query_socket: "/run/nix-swarm/query.sock",
  poll_interval_ms: 5_000,
  allowed_hosts: ["127.0.0.1", "nix-swarm-dev.localhost"]

config :nix_swarm_web, NixSwarmWeb.Endpoint,
  url: [host: "127.0.0.1"],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: NixSwarmWeb.PubSub,
  live_view: [signing_salt: "nix-swarm-web-live"]

config :tailwind,
  version: "4.3.0",
  nix_swarm_web: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/app.css),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

import_config "#{config_env()}.exs"

config :phoenix, :json_library, Jason
