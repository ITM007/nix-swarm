defmodule NixSwarmSecretsTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "nix-swarm-secrets-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)

    original_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

    on_exit(fn ->
      restore_env("PATH", original_path)
      File.rm_rf!(root)
    end)

    {:ok, root: root, bin_dir: bin_dir}
  end

  test "reads plaintext cookies and reports a missing cookie", %{root: root} do
    path = Path.join(root, "swarm.cookie")

    assert NixSwarm.Secrets.read_cookie(path) == nil

    File.write!(path, "  plaintext-cookie\n")
    assert NixSwarm.Secrets.read_cookie(path) == "plaintext-cookie"
  end

  test "prefers and decrypts an age-encrypted cookie", %{root: root, bin_dir: bin_dir} do
    install_executable(bin_dir, "rage", "#!/bin/sh\nprintf 'decrypted-cookie\\n'\n")

    path = Path.join(root, "swarm.cookie")
    File.write!(path, "plaintext-cookie")
    File.write!(path <> ".age", "ciphertext")

    assert NixSwarm.Secrets.read_cookie(path) == "decrypted-cookie"
  end

  test "encrypts through age without putting the secret in argv", %{root: root, bin_dir: bin_dir} do
    install_executable(bin_dir, "rage", "#!/bin/sh\ncat \"$6\" > \"$5\"\n")

    output = Path.join(root, "cookie.age")
    assert :ok = NixSwarm.Secrets.encrypt_cookie("secret-cookie", "age1recipient", output)
    assert File.read!(output) == "secret-cookie"
  end

  test "reports missing age tooling and non-zero decrypt results", %{root: root, bin_dir: bin_dir} do
    encrypted = Path.join(root, "broken.age")
    File.write!(encrypted, "ciphertext")

    assert_raise RuntimeError, ~r/age\/rage not found/, fn ->
      NixSwarm.Secrets.decrypt_age(encrypted)
    end

    install_executable(bin_dir, "age", "#!/bin/sh\nprintf 'bad identity'\nexit 7\n")

    assert_raise RuntimeError, ~r/age decryption failed \(status 7\): bad identity/, fn ->
      NixSwarm.Secrets.decrypt_age(encrypted)
    end
  end

  test "credential enrollment creates and reuses a private cookie", %{root: root} do
    path = Path.join(root, "nested/nix-swarm.cookie")

    cookie = NixSwarm.Credentials.ensure_local_cookie!(path)

    assert byte_size(cookie) in 32..64
    assert NixSwarm.Credentials.ensure_local_cookie!(path) == cookie
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
  end

  test "credential enrollment rejects malformed existing cookies", %{root: root} do
    path = Path.join(root, "bad.cookie")
    File.write!(path, "short\n")

    assert_raise ArgumentError, ~r/32-64 safe characters/, fn ->
      NixSwarm.Credentials.ensure_local_cookie!(path)
    end
  end

  defp install_executable(bin_dir, name, content) do
    path = Path.join(bin_dir, name)
    File.write!(path, content)
    File.chmod!(path, 0o700)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
