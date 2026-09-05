defmodule NixSwarmWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint NixSwarmWeb.Endpoint
      import Phoenix.ConnTest
      import Plug.Conn
    end
  end

  setup _tags do
    %{conn: Phoenix.ConnTest.build_conn()}
  end
end
