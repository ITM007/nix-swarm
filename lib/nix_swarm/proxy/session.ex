defmodule NixSwarm.Proxy.Session do
  @moduledoc false

  @aad "nix-swarm-session-v1"
  @version "v1"
  @minimum_secret_bytes 32
  @default_secret_name "proxy-session-secret"

  defstruct encryption_key: nil, signing_key: nil

  @type t() :: %__MODULE__{encryption_key: binary(), signing_key: binary()}

  def new(secret) when is_binary(secret) and byte_size(secret) >= @minimum_secret_bytes do
    {:ok,
     %__MODULE__{
       encryption_key: :crypto.hash(:sha256, "encryption:" <> secret),
       signing_key: :crypto.hash(:sha256, "signing:" <> secret)
     }}
  end

  def new(_secret), do: {:error, {:invalid_secret, :too_short}}

  def from_credentials(opts \\ []) do
    path =
      Keyword.get(opts, :session_secret_file) ||
        Path.join(
          Keyword.get(opts, :credentials_dir) ||
            System.get_env("CREDENTIALS_DIRECTORY", "/run/credentials"),
          Keyword.get(opts, :session_secret_name, @default_secret_name)
        )

    case File.read(path) do
      {:ok, secret} ->
        secret = secret |> String.trim_trailing("\n") |> String.trim_trailing("\r")

        case new(secret) do
          {:ok, session} -> {:ok, session}
          {:error, {:invalid_secret, reason}} -> {:error, {:invalid_secret, path, reason}}
        end

      {:error, reason} ->
        {:error, {:session_secret_unreadable, path, reason}}
    end
  end

  def encode(%__MODULE__{} = codec, session, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with :ok <- validate_session(session),
         :ok <- validate_not_expired(session, now) do
      plaintext = :erlang.term_to_binary(session, [:deterministic])
      nonce = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          codec.encryption_key,
          nonce,
          plaintext,
          @aad,
          true
        )

      payload =
        [@version, encode_part(nonce), encode_part(ciphertext), encode_part(tag)]
        |> Enum.join(".")

      signature = :crypto.mac(:hmac, :sha256, codec.signing_key, payload)
      {:ok, payload <> "." <> encode_part(signature)}
    end
  end

  def decode(codec, cookie, opts \\ [])

  def decode(%__MODULE__{} = codec, cookie, opts) when is_binary(cookie) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with [@version, nonce64, ciphertext64, tag64, signature64] <- String.split(cookie, "."),
         {:ok, nonce} <- decode_part(nonce64),
         {:ok, ciphertext} <- decode_part(ciphertext64),
         {:ok, tag} <- decode_part(tag64),
         {:ok, signature} <- decode_part(signature64),
         true <- Plug.Crypto.secure_compare(signature, signature_for(codec, cookie)),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             codec.encryption_key,
             nonce,
             ciphertext,
             @aad,
             tag,
             false
           ),
         {:ok, session} <- decode_term(plaintext),
         :ok <- validate_session(session),
         :ok <- validate_not_expired(session, now) do
      {:ok, session}
    else
      {:error, :expired} -> {:error, :expired}
      _ -> {:error, :invalid_cookie}
    end
  rescue
    ArgumentError -> {:error, :invalid_cookie}
  end

  def decode(_codec, _cookie, _opts), do: {:error, :invalid_cookie}

  defp validate_session(session) when is_map(session) do
    required = [:id_token, :refresh_token, :expires_at, :claims]

    cond do
      not Enum.all?(required, &Map.has_key?(session, &1)) ->
        {:error, {:invalid_session, :required_fields_missing}}

      not is_binary(session.id_token) or not is_binary(session.refresh_token) ->
        {:error, {:invalid_session, :tokens_must_be_strings}}

      not is_integer(session.expires_at) or not is_map(session.claims) ->
        {:error, {:invalid_session, :invalid_expiry_or_claims}}

      true ->
        :ok
    end
  end

  defp validate_session(_session), do: {:error, {:invalid_session, :must_be_map}}

  defp validate_not_expired(%{expires_at: expires_at}, now) when expires_at > now, do: :ok
  defp validate_not_expired(_session, _now), do: {:error, :expired}

  defp signature_for(%__MODULE__{} = codec, cookie) do
    [version, nonce, ciphertext, tag, _signature] = String.split(cookie, ".")

    :crypto.mac(
      :hmac,
      :sha256,
      codec.signing_key,
      Enum.join([version, nonce, ciphertext, tag], ".")
    )
  end

  defp encode_part(value), do: Base.url_encode64(value, padding: false)

  defp decode_part(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  defp decode_term(plaintext) do
    {:ok, :erlang.binary_to_term(plaintext, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid_term}
  end
end
