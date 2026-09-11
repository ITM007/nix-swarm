import Config

config :nix_swarm_web, NixSwarmWeb.Endpoint,
  server: false,
  secret_key_base: String.duplicate("a", 64),
  http: [ip: {127, 0, 0, 1}, port: 0]

config :nix_swarm_web, :allowed_hosts, ["www.example.com", "127.0.0.1", "nix-swarm-dev.localhost"]

config :nix_swarm_web, :query_broker, start: false
config :logger, level: :warning
