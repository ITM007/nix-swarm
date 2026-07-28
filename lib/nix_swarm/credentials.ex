defmodule NixSwarm.Credentials do
  @moduledoc false

  alias NixSwarm.Paths

  @target_path "/etc/nixos/nix-swarm/secrets/nix-swarm.cookie"
  @temporary_path @target_path <> ".new"
  @backup_path @target_path <> ".old"
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
    command_fun = Keyword.get(opts, :command_fun, &run_command/2)

    local_path =
      Keyword.get(opts, :secret_file, Path.join([source, "secrets", "nix-swarm.cookie"]))

    hosts = NixSwarm.Deploy.hosts(opts, source, paths.machines_dir)
    rotate? = Keyword.get(opts, :rotate_credentials, false) == true

    if hosts == [] do
      raise ArgumentError, "no deployment hosts were found for credential installation"
    end

    existing_cookie = ensure_local_cookie!(local_path)
    statuses = Map.new(hosts, &{&1, credential_status(&1, command_fun)})
    existing_hosts = for {host, {:present, _digest}} <- statuses, do: host

    matching_hosts =
      for {host, {:present, digest}} <- statuses,
          digest == cookie_digest(existing_cookie),
          do: host

    missing_hosts = for {host, :missing} <- statuses, do: host
    mismatched_hosts = existing_hosts -- matching_hosts

    if mismatched_hosts != [] and not rotate? do
      raise ArgumentError,
            "credential differs on #{Enum.join(mismatched_hosts, ", ")}; " <>
              "refusing to overwrite it without --rotate-credentials"
    end

    cookie =
      if rotate? do
        if missing_hosts != [] do
          raise ArgumentError,
                "cannot rotate credentials while hosts are missing the existing credential: " <>
                  Enum.join(missing_hosts, ", ")
        end

        new_cookie = rotate_local_cookie!(local_path)

        try do
          rotate_on_hosts!(hosts, local_path, command_fun)
        rescue
          error ->
            restore_local_cookie!(local_path, existing_cookie)
            reraise error, __STACKTRACE__
        end

        new_cookie
      else
        Enum.each(missing_hosts, &install_on_host!(&1, local_path, command_fun))
        existing_cookie
      end

    %{
      local_path: local_path,
      target_path: @target_path,
      hosts: hosts,
      unchanged_hosts: if(rotate?, do: [], else: matching_hosts),
      installed_hosts: if(rotate?, do: hosts, else: missing_hosts),
      rotated: rotate?,
      fingerprint: cookie_fingerprint(cookie)
    }
  end

  @doc false
  def rotate_local_cookie!(path) do
    path = Path.expand(path)
    directory = Path.dirname(path)
    File.mkdir_p!(directory)
    ensure_directory!(directory)
    File.chmod!(directory, 0o700)

    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        :ok

      {:ok, _metadata} ->
        raise ArgumentError, "cookie path must be a regular file, not a link or device: #{path}"

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise RuntimeError, "cannot inspect #{path}: #{:file.format_error(reason)}"
    end

    cookie = generate_cookie()
    temporary = path <> ".rotation-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, cookie <> "\n", [:exclusive])
      File.chmod!(temporary, 0o600)
      File.rename!(temporary, path)
      cookie
    after
      File.rm(temporary)
    end
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
          generated = generate_cookie()
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

  defp restore_local_cookie!(path, cookie) do
    temporary = path <> ".restore-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, cookie <> "\n", [:exclusive])
      File.chmod!(temporary, 0o600)
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp install_on_host!(host, local_path, command_fun) do
    stage_on_host!(host, local_path, command_fun)

    try do
      promote_on_host!(host, command_fun)
    rescue
      error ->
        safe_ssh(command_fun, host, "rm -f #{@temporary_path}")
        reraise error, __STACKTRACE__
    end
  rescue
    error ->
      raise RuntimeError,
            "credential installation failed on #{host}; use a root SSH deploy host or provision #{@target_path} declaratively: #{Exception.message(error)}"
  end

  defp credential_status(host, command_fun) do
    case command_fun.(
           "ssh",
           @ssh_options ++
             [
               "--",
               host,
               "if test -f #{@target_path}; then tr -d '\\r\\n' < #{@target_path} | sha256sum; else printf '%s\\n' '__NIX_SWARM_MISSING__'; fi"
             ]
         ) do
      {output, 0} ->
        case String.trim(output) do
          "__NIX_SWARM_MISSING__" ->
            :missing

          output ->
            case Regex.run(~r/\A([a-fA-F0-9]{64})\b/, output, capture: :all_but_first) do
              [digest] ->
                {:present, String.downcase(digest)}

              _ ->
                raise RuntimeError,
                      "credential preflight returned an invalid fingerprint on #{host}"
            end
        end

      {output, status} ->
        raise RuntimeError,
              "credential preflight failed on #{host} (#{status}): #{String.trim(output)}"
    end
  end

  defp stage_on_host!(host, local_path, command_fun) do
    run!(
      command_fun,
      "ssh",
      @ssh_options ++ ["--", host, "install -d -m 0700 /etc/nixos/nix-swarm/secrets"]
    )

    run!(
      command_fun,
      "scp",
      @ssh_options ++ ["-p", "--", local_path, "#{host}:#{@temporary_path}"]
    )
  end

  defp promote_on_host!(host, command_fun) do
    run!(
      command_fun,
      "ssh",
      @ssh_options ++
        [
          "--",
          host,
          "install -o root -g root -m 0400 #{@temporary_path} #{@target_path} && rm -f #{@temporary_path}"
        ]
    )
  end

  defp rotate_on_hosts!(hosts, local_path, command_fun) do
    try do
      Enum.each(hosts, fn host ->
        stage_on_host!(host, local_path, command_fun)

        run!(
          command_fun,
          "ssh",
          @ssh_options ++
            ["--", host, "install -o root -g root -m 0400 #{@target_path} #{@backup_path}"]
        )
      end)
    rescue
      error ->
        cleanup_rotation_artifacts!(hosts, command_fun)
        reraise error, __STACKTRACE__
    end

    try do
      Enum.each(
        hosts,
        &run!(command_fun, "ssh", @ssh_options ++ ["--", &1, "systemctl stop nix-swarmd.service"])
      )

      Enum.each(hosts, &promote_on_host!(&1, command_fun))

      Enum.each(
        hosts,
        &run!(
          command_fun,
          "ssh",
          @ssh_options ++ ["--", &1, "systemctl start nix-swarmd.service"]
        )
      )

      Enum.each(
        hosts,
        &run!(
          command_fun,
          "ssh",
          @ssh_options ++ ["--", &1, "systemctl is-active --quiet nix-swarmd.service"]
        )
      )

      cleanup_rotation_artifacts!(hosts, command_fun)
    rescue
      error ->
        rollback_rotation!(hosts, command_fun)

        raise RuntimeError,
              "credential rotation failed and the previous credential was restored: #{Exception.message(error)}"
    end
  end

  defp cleanup_rotation_artifacts!(hosts, command_fun) do
    Enum.each(hosts, &safe_ssh(command_fun, &1, "rm -f #{@backup_path} #{@temporary_path}"))
  end

  defp rollback_rotation!(hosts, command_fun) do
    Enum.each(hosts, fn host ->
      safe_ssh(command_fun, host, "systemctl stop nix-swarmd.service")

      safe_ssh(
        command_fun,
        host,
        "install -o root -g root -m 0400 #{@backup_path} #{@target_path}"
      )

      safe_ssh(command_fun, host, "rm -f #{@backup_path} #{@temporary_path}")
      safe_ssh(command_fun, host, "systemctl start nix-swarmd.service")
    end)
  end

  defp safe_ssh(command_fun, host, command) do
    _ = command_fun.("ssh", @ssh_options ++ ["--", host, command])
    :ok
  rescue
    _ -> :ok
  end

  defp run!(command_fun, executable, args) do
    case command_fun.(executable, args) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise RuntimeError, "#{executable} failed (#{status}): #{String.trim(output)}"
    end
  end

  defp run_command(executable, args), do: System.cmd(executable, args, stderr_to_stdout: true)

  defp generate_cookie, do: :crypto.strong_rand_bytes(36) |> Base.url_encode64(padding: false)

  defp valid_cookie?(cookie),
    do: byte_size(cookie) in 32..64 and String.match?(cookie, ~r/\A[A-Za-z0-9_.+\/=\-]+\z/)

  defp cookie_digest(cookie) do
    cookie
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp cookie_fingerprint(cookie), do: binary_part(cookie_digest(cookie), 0, 12)
end
