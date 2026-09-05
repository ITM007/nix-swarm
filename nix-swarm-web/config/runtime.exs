import Config

if config_env() == :prod do
  port = String.to_integer(System.get_env("PORT", "4000"))
  socket_path = System.get_env("NIX_SWARM_QUERY_SOCKET", "/run/nix-swarm/query.sock")
  poll_interval_ms = String.to_integer(System.get_env("NIX_SWARM_POLL_INTERVAL_MS", "5000"))
  secret_key_base_path = System.get_env("SECRET_KEY_BASE_FILE")

  secret_key_base =
    if is_binary(secret_key_base_path) do
      secret_key_base_path |> File.read!() |> String.trim()
    else
      raise "SECRET_KEY_BASE_FILE must point to a runtime-generated secret"
    end

  config :nix_swarm_web, :query_socket, socket_path
  config :nix_swarm_web, :poll_interval_ms, poll_interval_ms

  config :nix_swarm_web, NixSwarmWeb.Endpoint,
    server: true,
    secret_key_base: secret_key_base,
    http: [ip: {127, 0, 0, 1}, port: port]
end
