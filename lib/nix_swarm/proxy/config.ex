defmodule NixSwarm.Proxy.Config do
  @moduledoc false

  # Typed config for the optional built-in edge proxy (`NIX_SWARM_ROLE=proxy`).
  #
  # The NixOS module renders a public Erlang-terms file (no secrets) whose
  # body is a proplist of `{key, value}` tuples (nested attrset rendering).
  # Accepts maps, proplists, atom or binary keys, `:undefined` for absent
  # values, and binaries for strings — mirroring the cluster-config bridge
  # conventions. Secrets never appear here: they arrive via systemd
  # `LoadCredential` and are read directly from `$CREDENTIALS_DIRECTORY`.

  @default_session_ttl_sec 3600
  @default_scope "openid email profile"
  @upstream_regex ~r/^[A-Za-z0-9.-]+:[0-9]+$/
  @route_name_regex ~r/^[A-Za-z0-9][A-Za-z0-9._@-]*$/

  defmodule Route do
    @moduledoc false
    defstruct name: nil,
              host: nil,
              path_prefix: "/",
              upstreams: [],
              auth: :public,
              oidc: nil
  end

  defmodule Oidc do
    @moduledoc false
    @default_scope "openid email profile"
    defstruct issuer: nil,
              client_id: nil,
              scope: @default_scope,
              redirect_base: nil
  end

  defstruct listen_port: nil,
            session_ttl_sec: @default_session_ttl_sec,
            oidc: nil,
            routes: []

  def load_from_path(nil), do: nil

  def load_from_path(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, terms} ->
        {:ok, terms |> normalize_terms() |> normalize()}

      {:error, reason} ->
        {:error, "failed to read proxy config at #{path}: #{inspect(reason)}"}
    end
  end

  def normalize(raw) do
    raw = deep_to_map(raw)

    oidc =
      case NixSwarm.fetch_value(raw, :oidc, nil) do
        nil -> nil
        block -> normalize_oidc(block)
      end

    %__MODULE__{
      listen_port: NixSwarm.fetch_value(raw, :listen_port, nil),
      session_ttl_sec: NixSwarm.fetch_value(raw, :session_ttl_sec, @default_session_ttl_sec),
      oidc: oidc,
      routes:
        raw
        |> NixSwarm.fetch_value(:routes, [])
        |> List.wrap()
        |> Enum.map(&normalize_route/1)
    }
  end

  def validate(%__MODULE__{} = config) do
    errors =
      []
      |> validate_listen_port(config.listen_port)
      |> validate_routes(config)
      |> Enum.reverse()

    case errors do
      [] -> :ok
      messages -> {:error, Enum.join(messages, "; ")}
    end
  end

  # -- validation --------------------------------------------------------------

  defp validate_listen_port(errors, port) when is_integer(port) and port > 0,
    do: errors

  defp validate_listen_port(errors, _port),
    do: ["proxy config listen_port must be a positive integer" | errors]

  defp validate_routes(errors, config) do
    Enum.reduce(config.routes, errors, fn route, acc ->
      acc
      |> validate_route_name(route)
      |> validate_route_host(route)
      |> validate_route_path(route)
      |> validate_route_upstreams(route)
      |> validate_route_auth(route, config)
    end)
  end

  defp validate_route_name(errors, route) do
    if is_binary(route.name) and Regex.match?(@route_name_regex, route.name) and
         not String.contains?(route.name, "..") do
      errors
    else
      ["route name #{inspect(route.name)} is unsafe" | errors]
    end
  end

  defp validate_route_host(errors, route) do
    if is_binary(route.host) and route.host != "" do
      errors
    else
      ["route #{inspect(route.name)} has an empty host" | errors]
    end
  end

  defp validate_route_path(errors, route) do
    if is_binary(route.path_prefix) and
         String.starts_with?(route.path_prefix, "/") and
         not String.contains?(route.path_prefix, ["?", "#", "\\"]) do
      errors
    else
      ["route #{inspect(route.name)} path_prefix must be an absolute path" | errors]
    end
  end

  defp validate_route_upstreams(errors, route) do
    cond do
      route.upstreams == [] ->
        ["route #{inspect(route.name)} has no upstreams" | errors]

      Enum.any?(route.upstreams, &(not is_binary(&1))) ->
        ["route #{inspect(route.name)} has a non-string upstream" | errors]

      Enum.any?(route.upstreams, &(not valid_upstream?(&1))) ->
        [
          "route #{inspect(route.name)} upstream must be host:port without scheme or path"
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_route_auth(errors, route, config) do
    case route.auth do
      :public ->
        errors

      :oidc ->
        validate_oidc_route(errors, route, config)

      other ->
        ["route #{inspect(route.name)} has unknown auth tag #{inspect(other)}" | errors]
    end
  end

  defp validate_oidc_route(errors, route, config) do
    errors =
      case config.oidc && config.oidc.issuer do
        issuer when is_binary(issuer) and issuer != "" ->
          errors

        _ ->
          ["route #{inspect(route.name)} requires a top-level oidc.issuer" | errors]
      end

    case route.oidc && route.oidc.redirect_base do
      base when is_binary(base) ->
        if Regex.match?(~r/^https?:\/\/.+/, base) do
          errors
        else
          ["route #{inspect(route.name)} redirect_base must be absolute http(s)" | errors]
        end

      _ ->
        ["route #{inspect(route.name)} requires an oidc.redirect_base" | errors]
    end
  end

  # -- normalization helpers ---------------------------------------------------

  defp normalize_terms([single]) when is_list(single), do: single
  defp normalize_terms(terms) when is_list(terms), do: terms

  defp normalize_oidc(block), do: normalize_oidc(block, @default_scope)

  defp normalize_oidc(block, default_scope) do
    %Oidc{
      issuer: undef_to_nil(NixSwarm.fetch_value(block, :issuer, nil)),
      client_id: undef_to_nil(NixSwarm.fetch_value(block, :client_id, nil)),
      scope: undef_to_nil(NixSwarm.fetch_value(block, :scope, default_scope)) || default_scope,
      redirect_base: undef_to_nil(NixSwarm.fetch_value(block, :redirect_base, nil))
    }
  end

  defp normalize_route(route) do
    oidc =
      case undef_to_nil(NixSwarm.fetch_value(route, :oidc, nil)) do
        nil -> nil
        block -> normalize_oidc(block, nil)
      end

    %Route{
      name: undef_to_nil(NixSwarm.fetch_value(route, :name, nil)),
      host: undef_to_nil(NixSwarm.fetch_value(route, :host, nil)),
      path_prefix: NixSwarm.fetch_value(route, :path_prefix, "/"),
      upstreams:
        route
        |> NixSwarm.fetch_value(:upstreams, [])
        |> List.wrap(),
      auth: normalize_auth(NixSwarm.fetch_value(route, :auth, "public")),
      oidc: oidc
    }
  end

  defp normalize_auth(auth) when auth in [:public, "public"], do: :public
  defp normalize_auth(auth) when auth in [:oidc, "oidc"], do: :oidc
  defp normalize_auth(_other), do: :invalid

  defp undef_to_nil(:undefined), do: nil
  defp undef_to_nil(value), do: value

  defp valid_upstream?(upstream) when is_binary(upstream) do
    with true <- Regex.match?(@upstream_regex, upstream),
         [_host, port] <- String.split(upstream, ":", parts: 2),
         {port, ""} <- Integer.parse(port) do
      port in 1..65_535
    else
      _ -> false
    end
  end

  defp valid_upstream?(_upstream), do: false

  # Deep-convert proplists (`[{key, value}]`) and maps into maps with atom
  # keys, recursing into values; plain lists (e.g. the routes list) keep
  # their shape with each element converted in turn. Mirrors the term-bridge
  # contract: Nix attrset → proplist of `{key, value}` tuples.
  defp deep_to_map(value)

  defp deep_to_map(list) when is_list(list) do
    if keyword_list?(list) do
      list
      |> Map.new(fn {key, value} ->
        {key_to_atom(key), deep_to_map(value)}
      end)
    else
      Enum.map(list, &deep_to_map/1)
    end
  end

  defp deep_to_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {key_to_atom(key), deep_to_map(value)}
    end)
  end

  defp deep_to_map(value), do: value

  defp keyword_list?([]), do: false

  defp keyword_list?(list) do
    Enum.all?(list, fn
      {key, _value} when is_atom(key) or is_binary(key) -> true
      _ -> false
    end)
  end

  defp key_to_atom(key) when is_atom(key), do: key

  defp key_to_atom(key) when is_binary(key),
    do: String.to_existing_atom(key)
end
