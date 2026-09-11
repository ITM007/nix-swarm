defmodule NixSwarmWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    broker_opts = Application.get_env(:nix_swarm_web, :query_broker, [])

    children =
      [
        {Phoenix.PubSub, name: NixSwarmWeb.PubSub},
        {Task.Supervisor, name: NixSwarmWeb.QueryTaskSupervisor, max_children: 8},
        {NixSwarmWeb.QueryBroker, broker_opts},
        NixSwarmWeb.Endpoint
      ]
      |> Enum.reject(fn
        {NixSwarmWeb.QueryBroker, opts} -> Keyword.get(opts, :start, true) == false
        _child -> false
      end)

    opts = [strategy: :one_for_one, name: NixSwarmWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    NixSwarmWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
