defmodule NixSwarm.Secrets do
  @moduledoc """
  Decrypts age-encrypted secrets for GitOps workflows.

  Supports:
  - age encrypted files (via `rage` or `age` CLI)
  - Plaintext fallback when no encrypted file exists
  """

  @doc """
  Read a cookie, trying encrypted variants first.
  Order: swarm.cookie.age (rage decrypt) → swarm.cookie (plaintext)
  """
  def read_cookie(cookie_path) do
    age_path = cookie_path <> ".age"

    cond do
      File.exists?(age_path) ->
        decrypt_age(age_path)

      File.exists?(cookie_path) ->
        cookie_path |> File.read!() |> String.trim()

      true ->
        nil
    end
  end

  @doc """
  Decrypt an age-encrypted file and return the trimmed contents.
  Uses `rage` (Rust age implementation) falling back to `age`.
  """
  def decrypt_age(path) do
    age_bin = find_age_binary()

    case System.cmd(age_bin, ["--decrypt", path], stderr_to_stdout: true) do
      {output, 0} ->
        String.trim(output)

      {output, status} ->
        raise "age decryption failed (status #{status}): #{String.trim(output)}"
    end
  rescue
    error in [RuntimeError] ->
      raise error

    error ->
      raise "failed to decrypt #{path}: #{inspect(error)}"
  end

  @doc """
  Encrypt a cookie with age for Git committing.
  `recipient` is an age public key (age1...).
  """
  def encrypt_cookie(cookie, recipient, output_path) do
    age_bin = find_age_binary()

    case System.cmd(age_bin, ["--encrypt", "--recipient", recipient, "--output", output_path],
           stdin_data: cookie,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise "age encryption failed (status #{status}): #{String.trim(output)}"
    end
  end

  defp find_age_binary do
    cond do
      System.find_executable("rage") -> "rage"
      System.find_executable("age") -> "age"
      true -> raise "age/rage not found. Install 'rage' (nixpkgs#rage) or 'age'"
    end
  end
end
