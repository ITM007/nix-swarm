defmodule NixSwarmWeb.UIShellTest do
  use NixSwarmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias NixSwarmWeb.{
    DashboardLive,
    DriftLive,
    LogsLive,
    NetworkLive,
    NodeIndexLive,
    NodeShowLive,
    ServiceIndexLive,
    ServiceShowLive,
    SnapshotFixture
  }

  @css Path.expand("../../assets/css/app.css", __DIR__)
  @js Path.expand("../../assets/js/app.js", __DIR__)

  setup do
    context = SnapshotFixture.broker_setup(__MODULE__)
    on_exit(fn -> SnapshotFixture.stop(context) end)
    context
  end

  test "all LiveViews share the Phoenix application shell and theme control", %{conn: conn} do
    pages = [
      {DashboardLive, []},
      {NetworkLive, []},
      {NodeIndexLive, []},
      {NodeShowLive, [session: %{"node" => "bm9kZS1hQGNsdXN0ZXI"}]},
      {ServiceIndexLive, []},
      {ServiceShowLive, [session: %{"service" => "YXBp"}]},
      {DriftLive, []},
      {LogsLive, []}
    ]

    for {module, opts} <- pages do
      {:ok, _view, html} = live_isolated(conn, module, opts)

      assert html =~ "app-shell"
      assert html =~ ~s(data-theme-select)
      assert html =~ "System"
      assert html =~ "Light"
      assert html =~ "Dark"
      refute html =~ ~s(class="app-nav")
    end
  end

  test "assets follow Phoenix 1.8 LiveView Tailwind and daisyUI conventions" do
    css = File.read!(@css)
    js = File.read!(@js)

    assert css =~ ~s(@import "tailwindcss")
    assert css =~ ~s(@plugin "daisyui/packages/bundle/daisyui")
    assert css =~ ~s(@plugin "daisyui/packages/bundle/daisyui-theme")
    assert css =~ "@custom-variant dark (&:where([data-theme=dark], [data-theme=dark] *))"
    assert css =~ "phx-click-loading"
    assert css =~ "[data-phx-session]"
    assert css =~ ".app-shell--map"
    assert css =~ "100dvh"
    assert css =~ ".map-sidebar.is-collapsed"
    assert css =~ ".machine-enrollment-guide"
    assert css =~ ".machine-enrollment-modal"
    assert css =~ ".machine-enrollment-modal__instructions"
    assert css =~ ".map-config"
    assert css =~ ".map-config__code"
    assert css =~ ".tok-comment"
    assert css =~ ".tok-keyword"
    assert css =~ "--tok-string"
    assert css =~ ~s(html[data-theme="dark"] {\n  --tok-string)
    assert css =~ "html { font-size: 110%; }"
    assert js =~ "phx:theme"
    assert js =~ "data-theme"
  end
end
