defmodule NixSwarm.DevEnvironmentTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @script Path.join(@root, "scripts/dev.nu")
  @readme Path.join(@root, "README.md")
  @endpoint Path.join(@root, "nix-swarm-web/lib/nix_swarm_web/endpoint.ex")

  test "uses the user systemd manager instead of ad-hoc process supervision" do
    script = File.read!(@script)

    assert script =~ "systemd-run"
    assert script =~ "systemctl --user"
    refute script =~ "nohup"
    refute script =~ "query-tunnel.pid"
    refute script =~ "web.pid"
  end

  test "keeps Unix sockets outside the Nix path-flake source" do
    script = File.read!(@script)

    assert script =~ "XDG_RUNTIME_DIR"
    assert script =~ ~s(path join "nix-swarm-dev" $project)
    refute script =~ ~s(path join "_build" "dev-environment" $project)
  end

  test "Phoenix uses the pinned toolchain without an unbounded restart loop" do
    script = File.read!(@script)

    refute script =~ ~s("bash" "-lc" "mix deps.get && mix phx.server")
    assert script =~ ~s("nix" "develop" $root "--command" "mix" "phx.server")
    assert script =~ "--property=StartLimitBurst=3"
    assert script =~ "--property=StartLimitIntervalSec=30s"
  end

  test "help documents the isolated development origin" do
    {output, status} = System.cmd("nu", [@script, "help"], stderr_to_stdout: true)

    assert status == 0
    assert output =~ "nix-swarm-dev.localhost:4100"
    assert output =~ "Open this URL in your browser"
  end

  test "the web UI uses a dedicated session cookie name" do
    endpoint = File.read!(@endpoint)

    assert endpoint =~ ~s(key: "_nix_swarm_dev_web_key")
    refute endpoint =~ ~s(key: "_nix_swarm_web_key")
  end

  test "dev startup builds static assets for the prod-mode web unit" do
    script = File.read!(@script)

    assert script =~ "esbuild assets/js/app.js --bundle"
    assert script =~ "--alias:phoenix="
    assert script =~ "--alias:phoenix_live_view="
    assert script =~ ~s(priv/static/assets)
    assert script =~ "tailwindcss --input assets/css/app.css"
    refute script =~ ~s(cp assets/css/app.css priv/static/assets/app.css)
  end

  test "live views are not wrapped in the full-document root layout again" do
    web = File.read!(Path.join(@root, "nix-swarm-web/lib/nix_swarm_web.ex"))

    refute web =~ "layout: {NixSwarmWeb.Layouts, :root}"
    assert web =~ "use Phoenix.LiveView"
  end

  test "root README documents the one-command development workflow" do
    readme = File.read!(@readme)

    assert readme =~ "scripts/dev.nu up"
    assert readme =~ "scripts/dev.nu down"
    assert readme =~ "nix-swarm-dev.localhost:4100"
  end
end
