defmodule NixSwarmWeb.HostGuard do
  @moduledoc "Reject HTTP requests addressed to an unknown authority."

  import Plug.Conn

  @default_hosts ["127.0.0.1", "nix-swarm-dev.localhost"]

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if allowed_host?(conn.host) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(:bad_request, "invalid host\n")
      |> halt()
    end
  end

  @doc false
  @spec allowed_host?(term()) :: boolean()
  def allowed_host?(host) when is_binary(host) do
    normalized = String.downcase(host)
    allowed_hosts = Application.get_env(:nix_swarm_web, :allowed_hosts, @default_hosts)

    normalized in Enum.map(allowed_hosts, &String.downcase/1)
  end

  def allowed_host?(_host), do: false
end
