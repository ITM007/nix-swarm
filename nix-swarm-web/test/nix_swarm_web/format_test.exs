defmodule NixSwarmWeb.FormatTest do
  use ExUnit.Case, async: true

  alias NixSwarmWeb.Format

  test "formats bytes with stable IEC units and unknown values" do
    assert Format.bytes(0) == "0 B"
    assert Format.bytes(1_536) == "1.5 KiB"
    assert Format.bytes(2 * 1_024 * 1_024) == "2 MiB"
    assert Format.bytes(nil) == "unknown"
    assert Format.rate(1_536) == "1.5 KiB/s"
    assert Format.rate(nil) == "unknown"
  end

  test "formats durations and percentages without inventing unknown values" do
    assert Format.duration(3_661) == "1h 1m 1s"
    assert Format.duration_ms(1_500) == "1.5s"
    assert Format.percent(42.5) == "42.5%"
    assert Format.percent(42) == "42.0%"
    assert Format.percent(nil) == "unknown"
  end

  test "formats CPU usage as a percentage without exposing systemd nanoseconds" do
    now_ns = 4_000_000_000

    assert Format.cpu_percent(%{usage_ns: 42_000_000, started_at_ns: 2_000_000_000}, now_ns) ==
             "2.1%"

    assert Format.cpu_percent(%{pct: 2.1}, now_ns) == "2.1%"
    assert Format.cpu_percent(2, now_ns) == "2.0%"
    assert Format.cpu_percent(%{usage_ns: 42_000_000}, now_ns) == "unknown"
  end
end
