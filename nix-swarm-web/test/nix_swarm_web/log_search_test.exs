defmodule NixSwarmWeb.LogSearchTest do
  use ExUnit.Case, async: true

  alias NixSwarmWeb.LogSearch

  test "bounds lines and performs literal substring search without regex semantics" do
    lines = ["INFO [a.b]", "warning disk", "ERROR [a.b]", "needle"]

    result = LogSearch.search(lines, "[a.b]")
    assert result.lines == lines
    assert result.matches == [0, 2]
    assert LogSearch.find_matches(lines, "[a.b]") == [0, 2]

    oversized = Enum.map(1..1_001, &"line #{&1}")
    assert length(LogSearch.normalize_lines(oversized)) == 1_000
  end

  test "supports all, warnings-errors, and empty filters" do
    lines = ["INFO ok", "warning disk", "ERROR failed", "WARN retry", "debug"]

    assert LogSearch.filter(lines, :all) == lines

    assert LogSearch.filter(lines, "warnings-errors") == [
             "warning disk",
             "ERROR failed",
             "WARN retry"
           ]

    assert LogSearch.filter(lines, "errors") == ["ERROR failed"]
    assert LogSearch.filter(lines, "warnings") == ["warning disk", "WARN retry"]
    assert LogSearch.search(lines, "missing").matches == []
  end

  test "moves next and previous through bounded match indexes" do
    result = LogSearch.search(["hit", "none", "hit", "hit"], "hit")

    assert result.current_match == 0
    assert LogSearch.next_match(result).current_match == 1
    assert LogSearch.next_match(LogSearch.next_match(result)).current_match == 2

    assert LogSearch.next_match(LogSearch.next_match(LogSearch.next_match(result))).current_match ==
             0

    assert LogSearch.previous_match(result).current_match == 2
  end
end
