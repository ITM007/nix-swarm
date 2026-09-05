defmodule NixSwarm.ProxySessionTest do
  use ExUnit.Case, async: true

  alias NixSwarm.Proxy.Session

  @secret "0123456789abcdef0123456789abcdef"
  @session %{
    id_token: "id-token",
    refresh_token: "refresh-token",
    expires_at: 1_900_000_000,
    claims: %{"sub" => "user-1", "email" => "user@example.com"}
  }

  test "encrypted sessions round-trip claims" do
    assert {:ok, session} = Session.new(@secret)
    assert {:ok, cookie} = Session.encode(session, @session, now: 1_800_000_000)
    assert {:ok, @session} = Session.decode(session, cookie, now: 1_800_000_001)
    refute cookie =~ "user-1"
    refute cookie =~ "refresh-token"
  end

  test "tampered cookies are rejected" do
    {:ok, session} = Session.new(@secret)
    {:ok, cookie} = Session.encode(session, @session, now: 1_800_000_000)

    [version, nonce, ciphertext, tag, signature] = String.split(cookie, ".")
    <<first, rest::binary>> = signature
    tampered_signature = <<if(first == ?A, do: ?B, else: ?A), rest::binary>>
    tampered = Enum.join([version, nonce, ciphertext, tag, tampered_signature], ".")

    assert {:error, :invalid_cookie} = Session.decode(session, tampered, now: 1_800_000_001)
  end

  test "expired cookies are rejected" do
    {:ok, session} = Session.new(@secret)
    {:ok, cookie} = Session.encode(session, @session, now: 1_800_000_000)

    assert {:error, :expired} = Session.decode(session, cookie, now: 1_900_000_001)
  end

  test "short secrets are rejected when the session codec is created" do
    assert {:error, {:invalid_secret, :too_short}} = Session.new("too-short")
  end

  test "invalid session shapes are rejected before encryption" do
    {:ok, session} = Session.new(@secret)

    assert {:error, {:invalid_session, :required_fields_missing}} =
             Session.encode(session, %{claims: %{}}, now: 1_800_000_000)
  end
end
