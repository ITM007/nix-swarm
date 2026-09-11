defmodule NixSwarmWeb.DashboardConfigFilesTest do
  use NixSwarmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias NixSwarmWeb.{DashboardLive, SnapshotFixture}

  @fixture Path.expand("../fixtures/config_source", __DIR__)

  setup do
    context = SnapshotFixture.broker_setup(__MODULE__)
    on_exit(fn -> SnapshotFixture.stop(context) end)
    context
  end

  describe "config source sidebar" do
    setup do
      on_exit(fn -> Application.delete_env(:nix_swarm_web, :config_source) end)
      :ok
    end

    test "the section is absent when no source is configured", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, DashboardLive)

      assert html =~ ~s(data-config-section)
      assert html =~ "NIX_SWARM_CONFIG_SOURCE"
      refute html =~ "map-config__groups"
      refute html =~ "cluster.nix"
    end

    test "the section lists grouped configuration files read-only", %{conn: conn} do
      Application.put_env(:nix_swarm_web, :config_source, @fixture)
      {:ok, _view, html} = live_isolated(conn, DashboardLive)

      assert html =~ ~s(class="map-config")
      assert html =~ "cluster.nix"
      assert html =~ "flake.nix"
      assert html =~ ~s(data-config-group="Machines")
      assert html =~ ~s(<span class="map-config__file-name">node-a.nix</span>)
      assert html =~ ~s(data-config-group="Services")
      assert html =~ ~s(<span class="map-config__file-name">web.nix</span>)
      refute html =~ ~r{map-config__file-name">(?:machines|services)/}
      assert html =~ "read-only"
      refute html =~ "secrets/blocked.nix"
      refute html =~ "cookie-in-name.nix"
      refute html =~ ".git/"
    end

    test "the sidebar orders enrollment, file output, then config source", %{conn: conn} do
      Application.put_env(:nix_swarm_web, :config_source, @fixture)
      {:ok, _view, html} = live_isolated(conn, DashboardLive)

      enrollment = html |> :binary.match("machine-enrollment-guide") |> elem(0)
      output = html |> :binary.match("data-file-output") |> elem(0)
      source = html |> :binary.match("data-config-section") |> elem(0)

      assert enrollment < output
      assert output < source
      refute html =~ ~r{<h2>File output</h2>}
      refute html =~ ~r{<h2>Nix configuration</h2>}
    end

    test "file output shows an empty state until a file is selected", %{conn: conn} do
      Application.put_env(:nix_swarm_web, :config_source, @fixture)
      {:ok, _view, html} = live_isolated(conn, DashboardLive)

      assert html =~ ~s(data-file-output)
      assert html =~ ~s(data-file-output-empty)
      refute html =~ ~s(data-config-viewer)
    end

    test "configuration folders collapse and expand independently", %{conn: conn} do
      Application.put_env(:nix_swarm_web, :config_source, @fixture)
      {:ok, view, html} = live_isolated(conn, DashboardLive)

      assert html =~ ~s(data-config-group-toggle="Machines")
      assert html =~ ~s(data-config-group-toggle="Services")
      refute html =~ ~s(id="map-config-group-machines" class="map-config__files" hidden)

      view
      |> element(~s(button[data-config-group-toggle="Machines"]))
      |> render_click()

      html = render(view)

      assert html =~ ~s(id="map-config-group-machines" class="map-config__files" hidden)
      refute html =~ ~s(id="map-config-group-services" class="map-config__files" hidden)

      view
      |> element(~s(button[data-config-group-toggle="Machines"]))
      |> render_click()

      refute render(view) =~ ~s(id="map-config-group-machines" class="map-config__files" hidden)
    end

    test "opening a file renders syntax-highlighted Nix", %{conn: conn} do
      Application.put_env(:nix_swarm_web, :config_source, @fixture)
      {:ok, view, _html} = live_isolated(conn, DashboardLive)

      view
      |> element(~s(button[data-config-file][phx-value-rel="cluster.nix"]))
      |> render_click()

      html = render(view)

      assert html =~ ~s(data-config-viewer)
      assert html =~ "cluster.nix"
      assert html =~ ~s(class="tok-comment")
      assert html =~ "One-line fixture comment"
      assert html =~ ~s(class="tok-string")
      assert html =~ ~s(id="map-config-viewer-code")
      assert html =~ ~s(data-copy-target="map-config-viewer-code")
      assert html =~ ~s(phx-click="open_config_modal")
    end

    test "the opened file can be popped out into a modal", %{conn: conn} do
      Application.put_env(:nix_swarm_web, :config_source, @fixture)
      {:ok, view, _html} = live_isolated(conn, DashboardLive)

      view
      |> element(~s(button[data-config-file][phx-value-rel="cluster.nix"]))
      |> render_click()

      view
      |> element(~s(button[phx-click="open_config_modal"]))
      |> render_click()

      html = render(view)
      assert html =~ ~s(data-config-modal)
      assert html =~ ~s(role="dialog")
      assert html =~ ~s(id="map-config-modal-code")
      assert html =~ "One-line fixture comment"

      css = File.read!(Path.expand("../../assets/css/app.css", __DIR__))

      assert css =~
               "height: min(69rem, calc(100dvh - 2rem)); max-height: min(69rem, calc(100dvh - 2rem));"

      assert css =~ "html[data-theme=\"dark\"] .config-modal {"
      assert css =~ "background: color-mix(in oklab, #000 72%, transparent);"

      view
      |> element(~s(button[phx-click="close_config_modal"]))
      |> render_click()

      refute render(view) =~ ~s(data-config-modal)
    end

    test "closing the opened file removes the viewer", %{conn: conn} do
      Application.put_env(:nix_swarm_web, :config_source, @fixture)
      {:ok, view, _html} = live_isolated(conn, DashboardLive)

      view
      |> element(~s(button[data-config-file][phx-value-rel="cluster.nix"]))
      |> render_click()

      assert render(view) =~ ~s(data-config-viewer)

      view
      |> element(~s(button[phx-click="close_config_file"]))
      |> render_click()

      refute render(view) =~ ~s(data-config-viewer)
    end

    test "collapsing the section hides the file groups", %{conn: conn} do
      Application.put_env(:nix_swarm_web, :config_source, @fixture)
      {:ok, view, _html} = live_isolated(conn, DashboardLive)

      assert render(view) =~ ~s(<span class="map-config__file-name">node-a.nix</span>)

      view
      |> element(~s(button[phx-click="toggle_config_section"]))
      |> render_click()

      html = render(view)

      refute html =~ ~r{map-config__file-name">(?:machines|services)/}

      view
      |> element(~s(button[phx-click="toggle_config_section"]))
      |> render_click()

      assert render(view) =~ ~s(<span class="map-config__file-name">node-a.nix</span>)
    end

    test "selecting a map node opens its machine .nix file", %{conn: conn} do
      Application.put_env(:nix_swarm_web, :config_source, @fixture)
      {:ok, view, _html} = live_isolated(conn, DashboardLive)

      view
      |> render_hook("map_item_selected", %{"kind" => "node", "key" => "node-a@cluster"})

      html = render(view)

      assert html =~ ~s(data-config-viewer)
      assert html =~ "node-a.nix"
      assert html =~ "nodeName"
    end

    test "selecting an unmapped item shows a notice instead of a viewer", %{conn: conn} do
      Application.put_env(:nix_swarm_web, :config_source, @fixture)
      {:ok, view, _html} = live_isolated(conn, DashboardLive)

      view
      |> render_hook("map_item_selected", %{"kind" => "service", "key" => "missing-svc"})

      html = render(view)

      refute html =~ ~s(data-config-viewer)
      assert html =~ "No .nix file maps to service"
      assert html =~ "missing-svc"
    end

    test "file rows never expose excluded or unindexed paths", %{conn: conn} do
      Application.put_env(:nix_swarm_web, :config_source, @fixture)
      {:ok, view, _html} = live_isolated(conn, DashboardLive)

      html = render(view)
      refute html =~ "secrets/"
      refute html =~ "cookie-in-name.nix"
      refute html =~ "ignored.nix"

      view
      |> element(~s(button[phx-click="toggle_config_section"]))
      |> render_click()

      html = render(view)
      refute html =~ "secrets/"
      refute html =~ "cookie-in-name.nix"
      refute html =~ "ignored.nix"
    end
  end
end
