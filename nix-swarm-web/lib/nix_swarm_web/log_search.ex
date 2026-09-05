defmodule NixSwarmWeb.LogSearch do
  @moduledoc "Bounded, literal search over the current log result only."

  @max_lines 1_000

  @type result :: %{
          lines: [binary()],
          matches: [non_neg_integer()],
          query: binary(),
          filter: binary(),
          current_match: non_neg_integer() | nil
        }

  @doc "Normalizes a result to at most 1,000 text lines."
  def normalize_lines(lines, max_lines \\ @max_lines)

  def normalize_lines(lines, max_lines)
      when is_list(lines) and is_integer(max_lines) and max_lines > 0 do
    lines
    |> Enum.take(min(max_lines, @max_lines))
    |> Enum.map(&line_text/1)
  end

  def normalize_lines(_lines, _max_lines), do: []

  @doc "Returns lines matching a display filter; no regular expressions are used."
  def filter(lines, filter_name \\ :all) do
    lines = normalize_lines(lines)
    filter_name = normalize_filter(filter_name)

    Enum.filter(lines, fn line ->
      case filter_name do
        "all" -> true
        "warnings" -> contains_any?(line, ["warning", "warn"])
        "errors" -> contains?(line, "error")
        "warnings-errors" -> contains_any?(line, ["warning", "warn", "error"])
        _ -> true
      end
    end)
  end

  @doc "Searches the bounded, filtered current result for a literal substring."
  def search(lines, query \\ "", opts \\ [])

  def search(lines, query, opts) when is_list(opts) do
    filter_name = Keyword.get(opts, :filter, :all)
    build_result(lines, query, filter_name)
  end

  def search(lines, query, filter_name), do: build_result(lines, query, filter_name)

  @doc "Returns zero-based indexes of literal matches in the filtered result."
  def find_matches(lines, query, filter_name \\ :all) do
    search(lines, query, filter: filter_name).matches
  end

  @doc "Selects the next match, wrapping around the current result."
  def next_match(%{matches: []} = result), do: %{result | current_match: nil}

  def next_match(%{matches: matches, current_match: current} = result) do
    index = if is_integer(current), do: current, else: -1
    %{result | current_match: rem(index + 1, length(matches))}
  end

  @doc "Selects the previous match, wrapping around the current result."
  def previous_match(%{matches: []} = result), do: %{result | current_match: nil}

  def previous_match(%{matches: matches, current_match: current} = result) do
    index = if is_integer(current), do: current, else: 0
    %{result | current_match: rem(index - 1 + length(matches), length(matches))}
  end

  @doc "Extracts text lines from the accepted bounded log response shapes."
  def lines_from_response(response) when is_list(response), do: normalize_lines(response)

  def lines_from_response(response) when is_map(response) do
    response
    |> Map.get(
      "lines",
      Map.get(response, :lines, Map.get(response, "logs", Map.get(response, :logs, [])))
    )
    |> normalize_lines()
  end

  def lines_from_response(_response), do: []

  defp build_result(lines, query, filter_name) do
    filter_name = normalize_filter(filter_name)
    filtered = filter(lines, filter_name)
    query = if is_binary(query), do: query, else: to_string(query)

    matches =
      if query == "" do
        []
      else
        filtered
        |> Enum.with_index()
        |> Enum.filter(fn {line, _index} -> String.contains?(line, query) end)
        |> Enum.map(&elem(&1, 1))
      end

    %{
      lines: filtered,
      matches: matches,
      query: query,
      filter: filter_name,
      current_match: if(matches == [], do: nil, else: 0)
    }
  end

  defp normalize_filter(value) when value in [:all, "all"], do: "all"
  defp normalize_filter(value) when value in [:warnings, "warnings"], do: "warnings"
  defp normalize_filter(value) when value in [:errors, "errors"], do: "errors"

  defp normalize_filter(value) when value in [:"warnings-errors", "warnings-errors"],
    do: "warnings-errors"

  defp normalize_filter(_), do: "all"

  defp contains?(line, term), do: String.contains?(String.downcase(line), term)
  defp contains_any?(line, terms), do: Enum.any?(terms, &contains?(line, &1))
  defp line_text(value) when is_binary(value), do: value
  defp line_text(value), do: to_string(value)
end
