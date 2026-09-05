defmodule NixSwarmWeb.ErrorView do
  @moduledoc false

  @messages %{
    "404" => "Not Found",
    "500" => "Internal Server Error"
  }

  def render(template, _assigns) when is_binary(template) do
    status = Path.rootname(template)
    message = Map.get(@messages, status, @messages["500"])

    """
    <!doctype html>
    <html lang="en">
      <head><meta charset="utf-8"><title>#{status} #{message}</title></head>
      <body><h1>#{status} #{message}</h1></body>
    </html>
    """
  end
end
