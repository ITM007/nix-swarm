import Config

config :nix_swarm_web,
  query_socket: "/run/nix-swarm/query.sock",
  poll_interval_ms: 5_000

config :nix_swarm_web, NixSwarmWeb.Endpoint,
  url: [host: "127.0.0.1"],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: NixSwarmWeb.PubSub,
  live_view: [signing_salt: "nix-swarm-web-live"]

import_config "#{config_env()}.exs"

config :phoenix, :json_library, Jason
