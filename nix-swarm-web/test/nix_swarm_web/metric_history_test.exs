defmodule NixSwarmWeb.MetricHistoryTest do
  use ExUnit.Case, async: true

  alias NixSwarmWeb.MetricHistory

  test "retains a bounded ring of samples" do
    history = Enum.reduce(1..125, MetricHistory.new(120), &MetricHistory.push(&2, %{n: &1}))

    assert length(MetricHistory.samples(history)) == 120
    assert hd(MetricHistory.samples(history)) == %{n: 6}
    assert List.last(MetricHistory.samples(history)) == %{n: 125}
  end

  test "computes CPU and network counter deltas only for advancing timestamps" do
    previous = %{
      captured_at_ms: 1_000,
      metrics: %{
        cluster: %{cpu: %{used: 10, total: 20}, network: %{received: 100, transmitted: 50}}
      }
    }

    current = %{
      captured_at_ms: 3_000,
      metrics: %{
        cluster: %{cpu: %{used: 16, total: 20}, network: %{received: 160, transmitted: 80}}
      }
    }

    assert MetricHistory.delta(previous, current) == %{
             valid?: true,
             elapsed_ms: 2_000,
             cpu: %{used: 6, total: 20, rate: 3.0},
             network: %{received: 60, transmitted: 30, rate: 45.0}
           }

    regressed = put_in(current, [:metrics, :cluster, :network, :received], 90)
    assert MetricHistory.delta(previous, regressed).valid? == false
    assert MetricHistory.delta(current, put_in(current, [:captured_at_ms], 2_000)).valid? == false
  end

  test "accepts the agent CPU usage_ns counter as the CPU source" do
    previous = %{
      captured_at_ms: 1_000,
      metrics: %{cluster: %{cpu: %{usage_ns: 10}, network: %{received: 1, transmitted: 1}}}
    }

    current = %{
      captured_at_ms: 2_000,
      metrics: %{
        cluster: %{cpu: %{usage_ns: 30, total: 4}, network: %{received: 2, transmitted: 2}}
      }
    }

    assert MetricHistory.delta(previous, current).cpu == %{used: 20, total: 4, rate: 20.0}
  end
end
