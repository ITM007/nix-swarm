defmodule NixSwarm.Proxy.Auth do
  @moduledoc false

  alias NixSwarm.Proxy.Config
  alias NixSwarm.Proxy.Auth.Callback
  alias NixSwarm.Proxy.Forwarder
  alias NixSwarm.Proxy.Oidc
  alias NixSwarm.Proxy.Session

  @session_cookie "nix_swarm_session"
  @state_cookie "nix_swarm_auth_state"
  @callback_path "/__auth/callback"
  @state_ttl_sec 600

  def call(conn, route, opts \\ [])

  def call(conn, %Config.Route{auth: :public} = route, opts) do
    forwarder = Keyword.get(opts, :forwarder, &Forwarder.proxy/2)
    forwarder.(conn, route)
  end

  def call(conn, %Config.Route{auth: :oidc} = route, opts) do
    conn = Plug.Conn.fetch_cookies(conn)

    cond do
      conn.request_path == @callback_path ->
        Callback.call(conn, route, opts)

      true ->
        authenticated_or_login(conn, route, opts)
    end
  end

  def call(conn, _route, _opts), do: send_error(conn, 500, "invalid authentication configuration")

  defp authenticated_or_login(conn, route, opts) do
    with {:ok, session_codec} <- session_codec(opts),
         cookie when is_binary(cookie) <- conn.req_cookies[@session_cookie],
         {:ok, session} <- Session.decode(session_codec, cookie, now: now(opts)) do
      conn
      |> put_claim_headers(session.claims)
      |> forward(route, opts)
    else
      _ -> login(conn, route, opts)
    end
  end

  defp login(conn, route, opts) do
    with {:ok, oidc} <- oidc_client(route, opts),
         {:ok, session_codec} <- session_codec(opts),
         redirect_uri <- redirect_uri(route, oidc),
         {:ok, auth} <- Oidc.authorize(oidc, redirect_uri),
         state <- %{
           state: auth.state,
           pkce_verifier: auth.pkce_verifier,
           return_path: conn.request_path,
           return_query: conn.query_string,
           host: conn.host
         },
         {:ok, state_cookie} <- Session.encode_state(session_codec, state, now: now(opts)) do
      conn
      |> Plug.Conn.put_resp_cookie(
        @state_cookie,
        state_cookie,
        cookie_options(@state_ttl_sec, conn)
      )
      |> redirect(auth.authorization_url)
    else
      _ -> send_error(conn, 502, "authentication provider unavailable")
    end
  end

  @doc false
  def handle_callback(conn, route, opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    with {:ok, session_codec} <- session_codec(opts),
         state_cookie when is_binary(state_cookie) <- conn.req_cookies[@state_cookie],
         {:ok, state} <- Session.decode_state(session_codec, state_cookie, now: now(opts)),
         true <- secure_equal(state.state, conn.params["state"]),
         :ok <- valid_return_target(state, route, conn),
         code when is_binary(code) <- conn.params["code"],
         {:ok, oidc} <- oidc_client(route, opts),
         redirect_uri <- redirect_uri(route, oidc),
         {:ok, session_data} <- Oidc.exchange(oidc, code, redirect_uri, state.pkce_verifier),
         {:ok, session_cookie} <- Session.encode(session_codec, session_data, now: now(opts)) do
      conn
      |> Plug.Conn.delete_resp_cookie(@state_cookie, cookie_options(0, conn))
      |> Plug.Conn.put_resp_cookie(
        @session_cookie,
        session_cookie,
        cookie_options(session_ttl(opts), conn)
      )
      |> redirect(return_location(state))
    else
      _ -> send_error(conn, 400, "invalid authentication callback")
    end
  end

  defp session_codec(opts) do
    case Keyword.get(opts, :session) do
      %Session{} = session -> {:ok, session}
      nil -> Session.from_credentials(opts)
      _ -> {:error, :invalid_session_codec}
    end
  end

  defp oidc_client(route, opts) do
    case Keyword.get(opts, :oidc) do
      %Oidc{} = oidc ->
        {:ok, oidc}

      nil ->
        Oidc.new(effective_oidc_config(route, opts), opts)

      _ ->
        {:error, :invalid_oidc_client}
    end
  end

  defp valid_return_target(%{host: host, return_path: path}, route, conn)
       when is_binary(host) and is_binary(path) do
    prefix = String.trim_trailing(route.path_prefix, "/")

    if String.downcase(host) == String.downcase(conn.host) and
         (prefix == "" or path == prefix or String.starts_with?(path, prefix <> "/")) and
         not String.starts_with?(path, "//") do
      :ok
    else
      {:error, :invalid_return_path}
    end
  end

  defp valid_return_target(_state, _route, _conn), do: {:error, :invalid_return_target}

  defp redirect_uri(%Config.Route{oidc: %Config.Oidc{redirect_base: base}}, _oidc),
    do: String.trim_trailing(base, "/") <> @callback_path

  defp redirect_uri(%Config.Route{}, %Oidc{config: %Config.Oidc{redirect_base: base}}),
    do: String.trim_trailing(base, "/") <> @callback_path

  defp effective_oidc_config(route, opts) do
    top_level = get_in(opts, [:config, :oidc])

    case {top_level, route.oidc} do
      {%Config.Oidc{} = top, %Config.Oidc{} = route_config} ->
        %{top | redirect_base: route_config.redirect_base || top.redirect_base}

      {%Config.Oidc{} = top, _} ->
        top

      {_, %Config.Oidc{} = route_config} ->
        route_config

      _ ->
        %Config.Oidc{}
    end
  end

  defp return_location(state), do: state.return_path <> Map.get(state, :return_query, "")

  defp put_claim_headers(conn, claims) do
    Enum.reduce(claims, conn, fn
      {key, value}, conn when is_binary(value) or is_integer(value) or is_boolean(value) ->
        header = claim_header_name(key)
        value = to_string(value)

        if header && not String.contains?(value, ["\r", "\n"]) do
          conn
          |> Plug.Conn.delete_req_header(header)
          |> Plug.Conn.put_req_header(header, value)
        else
          conn
        end

      {_key, _value}, conn ->
        conn
    end)
  end

  defp claim_header_name(key) do
    key = key |> to_string() |> String.downcase()

    if Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, key) do
      "x-auth-" <> key
    end
  end

  defp forward(conn, route, opts) do
    Keyword.get(opts, :forwarder, &Forwarder.proxy/2).(conn, route)
  end

  defp redirect(conn, location),
    do: Plug.Conn.send_resp(Plug.Conn.put_resp_header(conn, "location", location), 302, "")

  defp send_error(conn, status, body), do: Plug.Conn.send_resp(conn, status, body)

  defp secure_equal(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal(_left, _right), do: false

  defp cookie_options(max_age, conn) do
    [
      http_only: true,
      secure: conn.scheme == :https,
      same_site: "Lax",
      path: "/",
      max_age: max_age
    ]
  end

  defp session_ttl(opts), do: Keyword.get(opts, :session_ttl_sec, 3600)
  defp now(opts), do: Keyword.get(opts, :now, System.system_time(:second))
end
