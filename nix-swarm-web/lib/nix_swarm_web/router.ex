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
    live("/", DashboardLive)
    # Keep legacy bookmarks working while presenting one map surface.
    live("/network", DashboardLive)
    live("/nodes", DashboardLive)
    live("/nodes/:node", DashboardLive)
    live("/services", DashboardLive)
    live("/services/:service", DashboardLive)
    live("/drift", DashboardLive)
    live("/logs", DashboardLive)

    get("/exports/snapshot.json", ExportController, :snapshot)
    get("/exports/nodes.csv", ExportController, :nodes)
    get("/exports/services.csv", ExportController, :services)
    get("/exports/logs.txt", ExportController, :logs)
  end
end
