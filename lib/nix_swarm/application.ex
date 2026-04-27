defmodule NixSwarm.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {NixSwarm.Cluster, []},
      {NixSwarm.Reconciler, []}
    ]

    opts = [strategy: :one_for_one, name: NixSwarm.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
