defmodule NixSwarmWeb.NixHighlighter do
  @moduledoc """
  Minimal server-side Nix syntax highlighter.

  Every piece of input is HTML-escaped before it is emitted, and tokens are
  wrapped in spans carrying a `tok-*` class. The output is therefore safe to
  render with `raw/1`: no input can introduce markup.

  Token coverage is deliberately conservative: line comments, double-quoted
  strings (including interpolation braces), angle paths, numbers, and the Nix
  language keywords. Identifiers and operators stay uncolored so the palette
  reads cleanly in both themes.
  """

  @keywords ~w(rec let in if then else assert with inherit or true false null)
  @keyword_set MapSet.new(@keywords)

  @token ~r/\A(?:#[^\n]*|"(?:[^"\\\n]|\\.)*"|<[^>\s]*>|\b(?:#{Enum.join(@keywords, "|")})\b|(?<![\w'-])\d+(?:\.\d+)?)/

  @doc "Highlights Nix source into escaped HTML with `tok-*` spans."
  @spec highlight(binary()) :: binary()
  def highlight(content) when is_binary(content) do
    content
    |> scan()
    |> Enum.map_join(&render/1)
  end

  defp scan(""), do: []

  defp scan(content) do
    case Regex.run(@token, content) do
      nil ->
        [
          {:plain, binary_part(content, 0, 1)}
          | scan(binary_part(content, 1, byte_size(content) - 1))
        ]

      [match] when match != "" ->
        size = byte_size(match)
        [{classify(match), match} | scan(binary_part(content, size, byte_size(content) - size))]

      [_zero_length] ->
        [
          {:plain, binary_part(content, 0, 1)}
          | scan(binary_part(content, 1, byte_size(content) - 1))
        ]
    end
  end

  defp classify(match) do
    cond do
      String.starts_with?(match, "#") -> :comment
      String.starts_with?(match, "\"") -> :string
      String.starts_with?(match, "<") -> :path
      MapSet.member?(@keyword_set, match) -> :keyword
      true -> :number
    end
  end

  defp render({:plain, text}), do: escape(text)

  defp render({type, text}) do
    ~s(<span class="tok-#{type}">#{escape(text)}</span>)
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
