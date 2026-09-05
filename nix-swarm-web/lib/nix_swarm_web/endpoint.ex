defmodule NixSwarmWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :nix_swarm_web

  @session_options [
    store: :cookie,
    key: "_nix_swarm_web_key",
    signing_salt: "nix-swarm-web-cookie",
    same_site: "Lax",
    http_only: true
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static,
    at: "/",
    from: :nix_swarm_web,
    gzip: false,
    only: ~w(assets favicon.ico)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(Plug.Parsers, parsers: [:urlencoded, :multipart], pass: ["*/*"])
  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(NixSwarmWeb.Router)
end
