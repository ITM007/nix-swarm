defmodule NixSwarmWeb do
  @moduledoc false

  def controller do
    quote do
      use Phoenix.Controller, formats: []

      import Plug.Conn
    end
  end

  def router do
    quote do
      use Phoenix.Router

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {NixSwarmWeb.Layouts, :root}
    end
  end

  defmacro __using__(which) when which in [:controller, :router, :live_view] do
    apply(__MODULE__, which, [])
  end
end
