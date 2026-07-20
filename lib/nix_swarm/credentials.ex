defmodule NixSwarm.Credentials do
  @moduledoc false

  alias NixSwarm.Paths

  @target_path "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie"
  @ssh_options [
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=10",
    "-o",
    "ServerAliveInterval=10",
    "-o",
    "ServerAliveCountMax=3",
    "-o",
    "StrictHostKeyChecking=yes",
    "-o",
    "ClearAllForwardings=yes",
    "-o",
    "ForwardAgent=no"
  ]

  def install(opts \\ []) do
    source = Keyword.get(opts, :source, Paths.default_source()) |> Path.expand()
    paths = NixSwarm.ConfigFiles.defaults(source)

    local_path =
      Keyword.get(opts, :secret_file, Path.join([source, "secrets", "nix-swarm.cookie"]))

    cookie = ensure_local_cookie!(local_path)
    hosts = NixSwarm.Deploy.hosts(opts, source, paths.machines_dir)
    rotate? = Keyword.get(opts, :rotate_credentials, false) == true

    if hosts == [] do
      raise ArgumentError, "no deployment hosts were found for credential installation"
    end

    existing_hosts = Enum.filter(hosts, &credential_exists?/1)

    if existing_hosts != [] and not rotate? do
      raise ArgumentError,
            "credential already exists on #{Enum.join(existing_hosts, ", ")}; " <>
              "refusing to overwrite it without --rotate-credentials"
    end

    Enum.each(hosts, &install_on_host!(&1, local_path))

    %{
      local_path: local_path,
      target_path: @target_path,
      hosts: hosts,
      rotated: rotate?,
      fingerprint: cookie_fingerprint(cookie)
    }
  end

  def ensure_local_cookie!(path) do
    path = Path.expand(path)
    directory = Path.dirname(path)
    File.mkdir_p!(directory)
    ensure_directory!(directory)
    File.chmod!(directory, 0o700)

    cookie =
      case File.lstat(path) do
        {:ok, %{type: :regular}} ->
          path |> File.read!() |> String.trim()

        {:ok, _metadata} ->
          raise ArgumentError, "cookie path must be a regular file, not a link or device: #{path}"

        {:error, :enoent} ->
          generated = :crypto.strong_rand_bytes(36) |> Base.url_encode64(padding: false)
          File.write!(path, generated <> "\n", [:exclusive])
          File.chmod!(path, 0o600)
          generated

        {:error, reason} ->
          raise RuntimeError, "cannot read #{path}: #{:file.format_error(reason)}"
      end

    unless valid_cookie?(cookie) do
      raise ArgumentError, "cookie at #{path} must contain 32-64 safe characters"
    end

    File.chmod!(path, 0o600)
    cookie
  end

  defp ensure_directory!(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, _metadata} ->
        raise ArgumentError, "credential directory must not be a symlink: #{path}"

      {:error, reason} ->
        raise RuntimeError, "cannot inspect #{path}: #{:file.format_error(reason)}"
    end
  end

  defp install_on_host!(host, local_path) do
    run!("ssh", @ssh_options ++ ["--", host, "install -d -m 0700 /etc/nixos/nix-swarm/secrets"])

    temporary = @target_path <> ".new"

    run!(
      "scp",
      @ssh_options ++ ["-p", "--", local_path, "#{host}:#{temporary}"]
    )

    run!(
      "ssh",
      @ssh_options ++
        [
          "--",
          host,
          "install -o root -g root -m 0400 #{temporary} #{@target_path} && rm -f #{temporary}"
        ]
    )
  rescue
    error ->
      raise RuntimeError,
            "credential installation failed on #{host}; use a root SSH deploy host or provision #{@target_path} declaratively: #{Exception.message(error)}"
  end

  defp credential_exists?(host) do
    case System.cmd(
           "ssh",
           @ssh_options ++ ["--", host, "test -e #{@target_path}"],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        true

      {_output, 1} ->
        false

      {output, status} ->
        raise RuntimeError,
              "credential preflight failed on #{host} (#{status}): #{String.trim(output)}"
    end
  end

  defp run!(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise RuntimeError, "#{executable} failed (#{status}): #{String.trim(output)}"
    end
  end

  defp valid_cookie?(cookie) do
    byte_size(cookie) in 32..64 and String.match?(cookie, ~r/\A[A-Za-z0-9_.+\/=\-]+\z/)
  end

  defp cookie_fingerprint(cookie) do
    cookie
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
