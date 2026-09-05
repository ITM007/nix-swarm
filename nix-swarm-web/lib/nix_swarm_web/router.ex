defmodule NixSwarmWeb.Router do
  @moduledoc false

  use NixSwarmWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {NixSwarmWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", NixSwarmWeb do
    pipe_through(:browser)

    get("/healthz", HealthController, :index)
  end
end
