defmodule NixSwarmWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: NixSwarmWeb.PubSub},
      NixSwarmWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: NixSwarmWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    NixSwarmWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
