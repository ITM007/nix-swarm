defmodule NixSwarmWeb.StatusComponents do
  @moduledoc "Reusable status presentation components for read-only views."

  use Phoenix.Component

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:tone, :string, default: "neutral")

  def summary_card(assigns) do
    ~H"""
    <article class={["card", "card-border", "summary-card", "summary-card--#{@tone}"]}>
      <p class="summary-card__label"><%= @label %></p>
      <p class="summary-card__value"><%= @value %></p>
    </article>
    """
  end

  attr(:label, :string, required: true)
  attr(:tone, :string, required: true)

  def status_badge(assigns) do
    ~H"""
    <span class={["badge", "status-badge", "status-badge--#{@tone}", "badge-#{badge_tone(@tone)}"]} role="status"><%= @label %></span>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  def metric_value(assigns) do
    ~H"""
    <div class="stat metric-value">
      <span class="metric-value__label"><%= @label %></span>
      <strong class="stat-value"><%= @value %></strong>
    </div>
    """
  end

  defp badge_tone(tone) when tone in ["healthy", "fresh", "good"], do: "success"
  defp badge_tone(tone) when tone in ["degraded", "stale", "warn"], do: "warning"
  defp badge_tone("bad"), do: "error"
  defp badge_tone(_), do: "neutral"
end
