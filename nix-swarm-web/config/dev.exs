import Config

config :nix_swarm_web, NixSwarmWeb.Endpoint,
  server: true,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  debug_errors: true,
  secret_key_base: String.duplicate("a", 64)
