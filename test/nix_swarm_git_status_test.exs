defmodule NixSwarmGitStatusTest do
  use ExUnit.Case, async: true

  alias NixSwarm.GitStatus

  test "clean working tree reports :clean" do
    fake = fn _cmd, _args, _opts -> {"", 0} end
    assert GitStatus.status("/some/path", fake) == :clean
  end

  test "modified and untracked files report :dirty in porcelain order" do
    fake = fn _cmd, _args, _opts ->
      {" M lib/nix_swarm/deploy.ex\n?? .hermes/plans/todo.md\n", 0}
    end

    assert GitStatus.status("/some/path", fake) ==
             {:dirty, [" M lib/nix_swarm/deploy.ex", "?? .hermes/plans/todo.md"]}
  end

  test "a directory that is not a git repository reports :not_a_repository" do
    fake = fn _cmd, _args, _opts ->
      {"fatal: not a git repository (or any of the parent directories): .git\n", 128}
    end

    assert GitStatus.status("/nix/store/checkout", fake) == :not_a_repository
  end

  test "a missing git binary reports :not_a_repository (nothing to check)" do
    fake = fn _cmd, _args, _opts -> raise ErlangError, original: :enoent end

    assert GitStatus.status("/some/path", fake) == :not_a_repository
  end

  test "git failures other than not-a-repository report an error" do
    fake = fn _cmd, _args, _opts -> {"fatal: could not open repository", 128} end

    assert GitStatus.status("/some/path", fake) ==
             {:error, 128, "fatal: could not open repository"}
  end
end
