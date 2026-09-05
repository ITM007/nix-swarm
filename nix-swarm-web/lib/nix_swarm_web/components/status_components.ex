defmodule NixSwarmWeb.StatusComponents do
  @moduledoc "Reusable status presentation components for read-only views."

  use Phoenix.Component

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:tone, :string, default: "neutral")

  def summary_card(assigns) do
    ~H"""
    <article class={["summary-card", "summary-card--#{@tone}"]}>
      <p class="summary-card__label"><%= @label %></p>
      <p class="summary-card__value"><%= @value %></p>
    </article>
    """
  end

  attr(:label, :string, required: true)
  attr(:tone, :string, required: true)

  def status_badge(assigns) do
    ~H"""
    <span class={["status-badge", "status-badge--#{@tone}"]} role="status"><%= @label %></span>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  def metric_value(assigns) do
    ~H"""
    <div class="metric-value">
      <span class="metric-value__label"><%= @label %></span>
      <strong><%= @value %></strong>
    </div>
    """
  end
end
