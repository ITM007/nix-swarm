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

  test "credential enrollment is idempotent when the remote fingerprint matches", %{root: root} do
    path = Path.join(root, "cluster.cookie")
    cookie = String.duplicate("a", 40)
    File.write!(path, cookie <> "\n")

    calls = start_supervised!({Agent, fn -> [] end}, id: :credential_calls)
    command_fun = recording_command_fun(calls, cookie_digest(cookie))

    result =
      NixSwarm.Credentials.install(
        source: root,
        hosts: ["root@node-a"],
        secret_file: path,
        command_fun: command_fun
      )

    assert result.unchanged_hosts == ["root@node-a"]
    assert result.installed_hosts == []
    refute Enum.any?(Agent.get(calls, & &1), &(&1 == "scp"))
  end

  test "credential enrollment installs only hosts without a cookie", %{root: root} do
    path = Path.join(root, "cluster.cookie")
    cookie = String.duplicate("a", 40)
    File.write!(path, cookie <> "\n")

    calls = start_supervised!({Agent, fn -> [] end}, id: :missing_credential_calls)

    command_fun = fn executable, args ->
      command = List.last(args)
      Agent.update(calls, &[command | &1])

      if executable == "ssh" and String.contains?(command, "sha256sum") do
        {"__NIX_SWARM_MISSING__\n", 0}
      else
        {"", 0}
      end
    end

    result =
      NixSwarm.Credentials.install(
        source: root,
        hosts: ["root@node-a"],
        secret_file: path,
        command_fun: command_fun
      )

    assert result.installed_hosts == ["root@node-a"]

    assert Enum.any?(
             Agent.get(calls, & &1),
             &String.contains?(&1, "node-a:/etc/nixos/nix-swarm/secrets/nix-swarm.cookie.new")
           )
  end

  test "credential preflight failures do not rotate the local cookie", %{root: root} do
    path = Path.join(root, "cluster.cookie")
    old_cookie = String.duplicate("a", 40)
    File.write!(path, old_cookie <> "\n")

    command_fun = fn executable, args ->
      command = List.last(args)

      if executable == "ssh" and String.contains?(command, "sha256sum") do
        {"host unreachable", 255}
      else
        {"", 0}
      end
    end

    assert_raise RuntimeError, ~r/credential preflight failed/, fn ->
      NixSwarm.Credentials.install(
        source: root,
        hosts: ["root@node-a"],
        secret_file: path,
        rotate_credentials: true,
        command_fun: command_fun
      )
    end

    assert File.read!(path) == old_cookie <> "\n"
  end

  test "enrollment refuses a different remote cookie without rotation", %{root: root} do
    path = Path.join(root, "cluster.cookie")
    cookie = String.duplicate("a", 40)
    File.write!(path, cookie <> "\n")

    assert_raise ArgumentError, ~r/credential differs/, fn ->
      NixSwarm.Credentials.install(
        source: root,
        hosts: ["root@node-a"],
        secret_file: path,
        command_fun: recording_command_fun(nil, String.duplicate("0", 64))
      )
    end
  end

  test "rotation generates a new cookie and coordinates every agent", %{root: root} do
    path = Path.join(root, "cluster.cookie")
    old_cookie = String.duplicate("a", 40)
    File.write!(path, old_cookie <> "\n")

    calls = start_supervised!({Agent, fn -> [] end}, id: :rotation_calls)
    command_fun = recording_command_fun(calls, cookie_digest(old_cookie))

    result =
      NixSwarm.Credentials.install(
        source: root,
        hosts: ["root@node-a", "root@node-b"],
        secret_file: path,
        rotate_credentials: true,
        command_fun: command_fun
      )

    assert result.rotated
    assert result.installed_hosts == ["root@node-a", "root@node-b"]
    refute File.read!(path) =~ old_cookie

    commands = Agent.get(calls, &Enum.reverse/1)
    assert Enum.count(commands, &String.contains?(&1, "systemctl stop nix-swarmd.service")) == 2
    assert Enum.count(commands, &String.contains?(&1, "systemctl start nix-swarmd.service")) == 2

    assert Enum.any?(
             commands,
             &String.contains?(&1, "systemctl is-active --quiet nix-swarmd.service")
           )
  end

  test "failed rotation restores the previous cookie", %{root: root} do
    path = Path.join(root, "cluster.cookie")
    old_cookie = String.duplicate("a", 40)
    File.write!(path, old_cookie <> "\n")

    command_fun = fn executable, args ->
      command = List.last(args)

      cond do
        executable == "ssh" and String.contains?(command, "sha256sum") ->
          {cookie_digest(old_cookie) <> "  -\n", 0}

        executable == "ssh" and String.contains?(command, "systemctl is-active") ->
          {"inactive", 1}

        true ->
          {"", 0}
      end
    end

    assert_raise RuntimeError, ~r/previous credential was restored/, fn ->
      NixSwarm.Credentials.install(
        source: root,
        hosts: ["root@node-a"],
        secret_file: path,
        rotate_credentials: true,
        command_fun: command_fun
      )
    end

    assert File.read!(path) == old_cookie <> "\n"
  end

  defp install_executable(bin_dir, name, content) do
    path = Path.join(bin_dir, name)
    File.write!(path, content)
    File.chmod!(path, 0o700)
  end

  defp recording_command_fun(calls, digest) do
    fn executable, args ->
      command = List.last(args)
      if calls, do: Agent.update(calls, &[command | &1])

      if executable == "ssh" and String.contains?(command, "sha256sum") do
        {digest <> "  -\n", 0}
      else
        {"", 0}
      end
    end
  end

  defp cookie_digest(cookie) do
    cookie
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
