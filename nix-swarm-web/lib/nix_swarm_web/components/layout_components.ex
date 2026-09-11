defmodule NixSwarmWeb.LayoutComponents do
  @moduledoc "Shared application shell for the read-only web views."

  use Phoenix.Component

  attr(:id, :string, required: true)
  attr(:current_path, :string, required: true)
  attr(:map_page, :boolean, default: false)
  slot(:inner_block, required: true)

  def app_shell(assigns) do
    ~H"""
    <main id={@id} class={[@map_page && "app-shell--map", "app-shell"]} data-read-only="true">
      <header class="navbar site-header">
        <a href="/" class="btn btn-ghost brand" aria-label="Nix-Swarm dashboard">
          <span class="brand-mark" aria-hidden="true">NS</span>
          <span>NIX-SWARM</span>
        </a>

        <div class="site-actions">
          <label class="theme-control">
            <span class="visually-hidden">Color theme</span>
            <select class="select select-bordered select-sm" data-theme-select="true" aria-label="Color theme">
              <option value="system">System</option>
              <option value="light">Light</option>
              <option value="dark">Dark</option>
            </select>
          </label>
          <span class="badge badge-outline read-only">read-only</span>
        </div>
      </header>

      <div class={[@map_page && "page-content--map", "page-content"]}>
        <%= render_slot(@inner_block) %>
      </div>
    </main>
    """
  end
end
