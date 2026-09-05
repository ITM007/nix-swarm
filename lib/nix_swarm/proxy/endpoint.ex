defmodule NixSwarm.Proxy.Endpoint do
  @moduledoc false

  # Plug endpoint for the built-in edge proxy. Matches requests against the
  # rendered route config (host + path prefix) and forwards them through
  # ReverseIt (HTTP and, later, WebSocket upgrades). The auth plug chain will
  # run between matching and forwarding once forward-auth lands, so WebSocket
  # handshakes are authenticated before any tunnel opens.

  @behaviour Plug

  alias NixSwarm.Proxy
  alias NixSwarm.Proxy.Forwarder

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Proxy.config() do
      nil ->
        conn
        |> Plug.Conn.send_resp(502, "")
        |> Plug.Conn.halt()

      config ->
        case Forwarder.route_for(conn, config) do
          nil ->
            conn
            |> Plug.Conn.send_resp(502, "")
            |> Plug.Conn.halt()

          route ->
            Forwarder.proxy(conn, route)
        end
    end
  end
end
