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
             network: %{received: 60, transmitted: 30, rate: 45.0},
             service_cpu: %{},
             node_network: %{},
             service_network: %{},
             proxy_network: %{}
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

  test "computes per-service CPU percentages from advancing usage_ns counters" do
    previous = %{
      captured_at_ms: 1_000,
      nodes: [%{name: "n1", metrics: %{cpu: %{total: 4}}}],
      services: [
        %{
          name: "api",
          slots: [
            %{
              slot: 0,
              unit: "api@0.service",
              owner: "n1",
              metrics: %{cpu: %{usage_ns: 1_000_000_000}}
            }
          ]
        }
      ]
    }

    current = %{
      captured_at_ms: 6_000,
      nodes: [%{name: "n1", metrics: %{cpu: %{total: 4}}}],
      services: [
        %{
          name: "api",
          slots: [
            %{
              slot: 0,
              unit: "api@0.service",
              owner: "n1",
              metrics: %{cpu: %{usage_ns: 3_000_000_000}}
            }
          ]
        }
      ]
    }

    assert %{"api|0|api@0.service" => pct} = MetricHistory.delta(previous, current).service_cpu
    assert_in_delta(pct, 10.0, 0.001)

    regressed =
      put_in(
        current,
        [:services, Access.at(0), :slots, Access.at(0), :metrics, :cpu, :usage_ns],
        500_000_000
      )

    assert MetricHistory.delta(previous, regressed).service_cpu == %{
             "api|0|api@0.service" => nil
           }
  end

  test "computes directional network rates for nodes and service slots" do
    previous = %{
      captured_at_ms: 1_000,
      nodes: [
        %{name: "n1", metrics: %{network: %{received: 100, transmitted: 40}}}
      ],
      services: [
        %{
          name: "api",
          slots: [
            %{
              slot: 0,
              unit: "api@0.service",
              owner: "n1",
              metrics: %{network: %{received: 10, transmitted: 5}}
            }
          ]
        }
      ]
    }

    current = %{
      captured_at_ms: 3_000,
      nodes: [
        %{name: "n1", metrics: %{network: %{received: 500, transmitted: 140}}}
      ],
      services: [
        %{
          name: "api",
          slots: [
            %{
              slot: 0,
              unit: "api@0.service",
              owner: "n1",
              metrics: %{network: %{received: 110, transmitted: 45}}
            }
          ]
        }
      ]
    }

    delta = MetricHistory.delta(previous, current)

    assert delta.node_network["n1"] == %{
             received: 400,
             transmitted: 100,
             total: 500,
             rate: 250.0
           }

    assert delta.service_network["api|0|api@0.service"] == %{
             received: 100,
             transmitted: 40,
             total: 140,
             rate: 70.0
           }
  end
end
