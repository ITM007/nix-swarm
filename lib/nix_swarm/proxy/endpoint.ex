defmodule NixSwarm.Proxy.Endpoint do
  @moduledoc false

  @behaviour Plug

  alias NixSwarm.Proxy
  alias NixSwarm.Proxy.Auth
  alias NixSwarm.Proxy.Forwarder

  @callback_path "/__auth/callback"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    case Proxy.config() do
      nil ->
        conn
        |> Plug.Conn.send_resp(502, "")
        |> Plug.Conn.halt()

      config ->
        case route_for(conn, config) do
          nil ->
            conn
            |> Plug.Conn.send_resp(502, "")
            |> Plug.Conn.halt()

          route ->
            Auth.call(conn, route, Keyword.put(opts, :config, config))
        end
    end
  end

  defp route_for(conn, config) do
    Forwarder.route_for(conn, config) || callback_route_for(conn, config)
  end

  defp callback_route_for(%Plug.Conn{request_path: @callback_path} = conn, config) do
    Enum.find(config.routes, fn route ->
      route.auth == :oidc and String.downcase(route.host) == String.downcase(conn.host)
    end)
  end

  defp callback_route_for(_conn, _config), do: nil
end
