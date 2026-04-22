defmodule Swarm.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Swarm.Cluster, []},
      {Swarm.Reconciler, []}
    ]

    opts = [strategy: :one_for_one, name: Swarm.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
