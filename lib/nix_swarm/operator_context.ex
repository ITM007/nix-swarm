defmodule NixSwarm.OperatorContext do
  @moduledoc """
  Shared normalized inputs for the CLI and read-only TUI.

  This is an ephemeral operator context, not a desired-state store. Durable
  configuration remains in the evaluated Nix source tree.
  """

  alias NixSwarm.{ConfigFiles, Remote}

  @type t :: %{
          source: String.t(),
          paths: map(),
          remote: map() | nil,
          read_only?: true
        }

  @spec from_opts(keyword()) :: t()
  def from_opts(opts) when is_list(opts) do
    source = Keyword.get(opts, :source) || NixSwarm.Paths.default_source()
    defaults = ConfigFiles.defaults(source)

    paths =
      ConfigFiles.normalize_paths(%{
        source: source,
        cluster_file: Keyword.get(opts, :cluster_file, defaults.cluster_file),
        machines_dir: Keyword.get(opts, :machines_dir, defaults.machines_dir),
        services_dir: Keyword.get(opts, :services_dir, defaults.services_dir)
      })

    remote =
      if Keyword.has_key?(opts, :target) do
        Remote.options!(Keyword.take(opts, [:target, :ssh_host]))
      end

    %{source: paths.source, paths: paths, remote: remote, read_only?: true}
  end

  def paths(opts), do: from_opts(opts).paths

  def remote(opts) do
    case from_opts(opts).remote do
      nil -> raise ArgumentError, "missing required --target for remote command"
      remote -> remote
    end
  end
end
