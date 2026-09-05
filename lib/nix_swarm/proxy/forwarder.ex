defmodule NixSwarm.Proxy.Forwarder do
  @moduledoc false

  # Route matching + ReverseIt forwarding for the built-in edge proxy.
  #
  # ReverseIt scopes are single-`:backend` (one Finch pool per forward), so a
  # route with several static upstreams needs a picker in front: before
  # delegating, the forwarder probe-connects candidates in config order and
  # delegates to the first one accepting TCP. This is a v1 liveness probe at
  # request time only — it never starts/stops units, so the reconciler stays
  # the authority on placement; the upstream registry (cluster-state driven)
  # is the scheduled follow-on that replaces the probe.
  #
  # ReverseIt always halts the connection and streams responses progressively
  # (chunked), so a failed attempt cannot be replayed on the same conn: probe
  # first, delegate once.

  @probe_timeout_ms 300
  @pool :nix_swarm_proxy_pool

  alias NixSwarm.Proxy.Config

  def route_for(conn, %Config{} = config) do
    host = String.downcase(conn.host)

    Enum.find(config.routes, fn route ->
      String.downcase(route.host) == host and
        String.starts_with?(conn.request_path, route.path_prefix)
    end)
  end

  def proxy(conn, %Config.Route{} = route) do
    case pick_upstream(route.upstreams) do
      {:ok, upstream} ->
        ReverseIt.call(
          conn,
          ReverseIt.init(
            name: @pool,
            backend: "http://#{upstream}",
            protocols: [:http1],
            response_header_retries: 1
          )
        )
        |> Plug.Conn.halt()

      :none ->
        conn
        |> Plug.Conn.send_resp(502, "")
        |> Plug.Conn.halt()
    end
  end

  defp pick_upstream([single]), do: {:ok, single}

  defp pick_upstream(upstreams) do
    Enum.find_value(upstreams, :none, fn upstream ->
      if reachable?(upstream), do: {:ok, upstream}
    end)
  end

  defp reachable?(upstream) do
    case String.split(upstream, ":", parts: 2) do
      [host, port] ->
        case :gen_tcp.connect(
               String.to_charlist(host),
               String.to_integer(port),
               [:binary],
               @probe_timeout_ms
             ) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            true

          {:error, _reason} ->
            false
        end

      _ ->
        false
    end
  end
end
