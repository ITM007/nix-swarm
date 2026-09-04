defmodule NixSwarm.GitStatus do
  @moduledoc """
  Reports whether a local source tree has uncommitted changes.

  Deployments are only reproducible from a committed tree, so `cluster
  apply` refuses a dirty tree unless the operator explicitly waives the
  guard with `--allow-dirty`. Trees that are not git checkouts (release
  tarballs, `/nix/store` sources) have no working tree to drift and report
  `:not_a_repository`.
  """

  @doc """
  Returns `:clean`, `{:dirty, porcelain_lines}`, `:not_a_repository`, or
  `{:error, exit_code, output}`.

  `command_fun` defaults to `System.cmd/3` and is injectable for tests.
  Untracked files count as dirt: a new machine file would change the
  deployment even though tracked files are untouched.
  """
  def status(path, command_fun \\ &System.cmd/3) do
    case run_git(path, command_fun) do
      :git_missing -> :not_a_repository
      {output, exit_code} -> classify(output, exit_code)
    end
  end

  defp run_git(path, command_fun) do
    command_fun.(
      "git",
      ["status", "--porcelain", "--untracked-files=normal"],
      cd: path,
      stderr_to_stdout: true
    )
  rescue
    e in ErlangError ->
      if e.original == :enoent or e.reason == :enoent do
        # git is not installed; there is no repository state to check
        :git_missing
      else
        reraise e, __STACKTRACE__
      end
  end

  defp classify(output, exit_code) do
    cond do
      exit_code == 0 ->
        case output |> String.split("\n", trim: true) do
          [] -> :clean
          lines -> {:dirty, lines}
        end

      not_a_repository?(output) ->
        :not_a_repository

      true ->
        {:error, exit_code, String.trim(output)}
    end
  end

  defp not_a_repository?(output) do
    output =~ "not a git repository"
  end
end
