defmodule NixSwarm.Proxy.Oidc do
  @moduledoc false

  alias NixSwarm.Proxy.Config

  @default_client_secret_name "proxy-client-secret"
  @provider_prefix "nix_swarm_oidc_"

  defstruct config: nil,
            client_secret: nil,
            provider: Oidcc,
            provider_ref: nil

  @type t() :: %__MODULE__{
          config: Config.Oidc,
          client_secret: String.t(),
          provider: module(),
          provider_ref: term()
        }

  @doc "Build an OIDC client, reading the client secret from credentials when needed."
  def new(config, opts \\ [])

  def new(%Config.Oidc{} = config, opts) do
    with :ok <- validate_issuer(config.issuer),
         {:ok, client_secret} <- client_secret(opts),
         {:ok, provider_ref} <- provider_ref(config, opts) do
      {:ok,
       %__MODULE__{
         config: config,
         client_secret: client_secret,
         provider: Keyword.get(opts, :provider, Oidcc),
         provider_ref: provider_ref
       }}
    end
  end

  def new(_config, _opts), do: {:error, {:invalid_config, :oidc}}

  @doc "Create an authorization URL and the verifier/state needed for the callback."
  def authorize(oidc, redirect_uri, opts \\ [])

  def authorize(%__MODULE__{} = oidc, redirect_uri, opts) when is_binary(redirect_uri) do
    state = random_value()
    pkce_verifier = random_value()
    nonce = random_value()

    oidcc_opts = %{
      redirect_uri: redirect_uri,
      scopes: scopes(oidc.config.scope),
      state: state,
      pkce_verifier: pkce_verifier,
      nonce: nonce,
      require_pkce: true
    }

    oidcc_opts = Map.merge(oidcc_opts, Map.new(opts))

    case call_provider(oidc, :create_redirect_url, [
           oidc.provider_ref,
           oidc.config.client_id,
           oidc.client_secret,
           oidcc_opts
         ]) do
      {:ok, authorization_url} when is_binary(authorization_url) ->
        {:ok,
         %{
           authorization_url: authorization_url,
           state: state,
           pkce_verifier: pkce_verifier,
           nonce: nonce
         }}

      {:ok, authorization_url} ->
        {:error, {:oidc_error, {:invalid_authorization_url, authorization_url}}}

      {:error, reason} ->
        {:error, {:oidc_error, reason}}
    end
  end

  def authorize(_oidc, _redirect_uri, _opts),
    do: {:error, {:invalid_redirect_uri, :must_be_binary}}

  @doc "Exchange an authorization code and return the validated session token shape."
  def exchange(%__MODULE__{} = oidc, code, redirect_uri, pkce_verifier)
      when is_binary(code) and is_binary(redirect_uri) and is_binary(pkce_verifier) do
    exchange(oidc, code, redirect_uri, pkce_verifier, nil)
  end

  def exchange(_oidc, _code, _redirect_uri, _pkce_verifier),
    do: {:error, {:invalid_exchange, :missing_parameter}}

  def exchange(%__MODULE__{} = oidc, code, redirect_uri, pkce_verifier, nonce)
      when is_binary(code) and is_binary(redirect_uri) and is_binary(pkce_verifier) and
             is_binary(nonce) do
    opts = %{
      redirect_uri: redirect_uri,
      pkce_verifier: pkce_verifier,
      nonce: nonce,
      require_pkce: true
    }

    retrieve_token(oidc, code, opts)
  end

  def exchange(%__MODULE__{} = oidc, code, redirect_uri, pkce_verifier, nil)
      when is_binary(code) and is_binary(redirect_uri) and is_binary(pkce_verifier) do
    opts = %{redirect_uri: redirect_uri, pkce_verifier: pkce_verifier, require_pkce: true}

    retrieve_token(oidc, code, opts)
  end

  def exchange(_oidc, _code, _redirect_uri, _pkce_verifier, _nonce),
    do: {:error, {:invalid_exchange, :missing_parameter}}

  defp retrieve_token(oidc, code, opts) do
    case call_provider(
           oidc,
           :retrieve_token,
           [code, oidc.provider_ref, oidc.config.client_id, oidc.client_secret, opts]
         ) do
      {:ok, token} -> normalize_token(token)
      {:error, reason} -> {:error, {:oidc_error, reason}}
    end
  end

  @doc "Refresh the session token through the provider's refresh grant."
  def refresh(%__MODULE__{} = oidc, %{refresh_token: refresh_token, claims: claims})
      when is_binary(refresh_token) and is_map(claims) do
    opts = if is_binary(claims["sub"]), do: %{expected_subject: claims["sub"]}, else: %{}

    case call_provider(
           oidc,
           :refresh_token,
           [refresh_token, oidc.provider_ref, oidc.config.client_id, oidc.client_secret, opts]
         ) do
      {:ok, token} -> normalize_token(token)
      {:error, reason} -> {:error, {:oidc_error, reason}}
    end
  end

  def refresh(_oidc, _session), do: {:error, {:invalid_session, :refresh_token_required}}

  defp validate_issuer(issuer) when is_binary(issuer) do
    case URI.parse(issuer) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _ ->
        {:error, {:invalid_issuer, :must_be_http_or_https}}
    end
  end

  defp validate_issuer(_issuer), do: {:error, {:invalid_issuer, :must_be_http_or_https}}

  defp client_secret(opts) do
    case Keyword.get(opts, :client_secret) do
      secret when is_binary(secret) and secret != "" ->
        {:ok, secret}

      nil ->
        path =
          Keyword.get(opts, :client_secret_file) ||
            Path.join(
              credentials_dir(opts),
              Keyword.get(opts, :client_secret_name, @default_client_secret_name)
            )

        case File.read(path) do
          {:ok, secret} when byte_size(secret) > 0 ->
            {:ok, secret |> String.trim_trailing("\n") |> String.trim_trailing("\r")}

          {:ok, _empty} ->
            {:error, {:missing_client_secret, path}}

          {:error, reason} ->
            {:error, {:client_secret_unreadable, path, reason}}
        end

      _ ->
        {:error, {:invalid_client_secret, :must_be_non_empty}}
    end
  end

  defp credentials_dir(opts),
    do:
      Keyword.get(opts, :credentials_dir) ||
        System.get_env("CREDENTIALS_DIRECTORY", "/run/credentials")

  defp provider_ref(config, opts) do
    case Keyword.fetch(opts, :provider_ref) do
      {:ok, ref} -> {:ok, ref}
      :error -> start_provider_worker(config.issuer)
    end
  end

  defp start_provider_worker(issuer) do
    name = String.to_atom(@provider_prefix <> Integer.to_string(:erlang.phash2(issuer)))

    case Oidcc.ProviderConfiguration.Worker.start_link(%{name: name, issuer: issuer}) do
      {:ok, _pid} -> {:ok, name}
      {:error, {:already_started, _pid}} -> {:ok, name}
      {:error, reason} -> {:error, {:provider_start_failed, reason}}
    end
  end

  defp call_provider(%__MODULE__{provider: provider}, function, args) do
    apply(provider, function, args)
  rescue
    error -> {:error, {:provider_exception, error}}
  catch
    kind, reason -> {:error, {:provider_throw, kind, reason}}
  end

  defp normalize_token(%Oidcc.Token{} = token) do
    id = token.id
    refresh = token.refresh
    access = token.access

    with %Oidcc.Token.Id{token: id_token, claims: claims} <- id,
         %Oidcc.Token.Refresh{token: refresh_token} <- refresh,
         %Oidcc.Token.Access{expires: expires_in} <- access,
         {:ok, expires_at} <- absolute_expiry(expires_in) do
      {:ok,
       %{id_token: id_token, refresh_token: refresh_token, expires_at: expires_at, claims: claims}}
    else
      _ -> {:error, {:invalid_token, :required_fields_missing}}
    end
  end

  defp normalize_token(token) when is_map(token) do
    required = [:id_token, :refresh_token, :expires_at, :claims]

    if Enum.all?(required, &Map.has_key?(token, &1)) and is_map(token.claims) do
      {:ok, Map.take(token, required)}
    else
      {:error, {:invalid_token, :required_fields_missing}}
    end
  end

  defp normalize_token(_token), do: {:error, {:invalid_token, :unexpected_shape}}

  defp absolute_expiry(expires_in) when is_integer(expires_in) and expires_in > 0,
    do: {:ok, System.system_time(:second) + expires_in}

  defp absolute_expiry(_expires_in), do: {:error, {:invalid_token, :invalid_expiry}}

  defp scopes(scope) when is_binary(scope), do: String.split(scope, ~r/\s+/, trim: true)
  defp scopes(scope) when is_list(scope), do: scope
  defp scopes(_scope), do: ["openid"]

  defp random_value do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end
end
