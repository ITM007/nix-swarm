defmodule NixSwarmWeb.HealthController do
  @moduledoc false

  use NixSwarmWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"status":"ok"}))
  end
end
