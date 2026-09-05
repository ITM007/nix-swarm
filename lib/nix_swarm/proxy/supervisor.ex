defmodule NixSwarm.Proxy.Supervisor do
  @moduledoc false

  # Boots the edge proxy runtime for the `proxy` role: loads the rendered
  # config (fail-closed on missing/invalid config — no listener without
  # validated routes) and starts the Bandit HTTP endpoint.
  #
  # Bandit is required over plain Plug.Cowboy: ReverseIt's WebSocket upgrade
  # path is a WebSock upgrade, which only Bandit (or Cowboy through websock
  # plumbing) supports. Pin discipline: the release pins Bandit past
  # CVE-2026-42786 (unbounded WS continuation-frame accumulation).

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = NixSwarm.Proxy.load_config!()

    children = [
      {ReverseIt, name: :nix_swarm_proxy_pool, pool_size: 50},
      {Bandit, plug: {NixSwarm.Proxy.Endpoint, []}, port: config.listen_port}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
