defmodule NixSwarm.Proxy.Auth.Callback do
  @moduledoc false

  alias NixSwarm.Proxy.Auth

  def call(conn, route, opts), do: Auth.handle_callback(conn, route, opts)
end
