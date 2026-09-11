defmodule NixSwarmWeb.NixHighlighterTest do
  use ExUnit.Case, async: true

  alias NixSwarmWeb.NixHighlighter

  test "empty input renders an empty string" do
    assert NixSwarmWeb.NixHighlighter.highlight("") == ""
  end

  test "plain text is HTML-escaped without spans" do
    html = NixHighlighter.highlight("a < b && c > d")

    assert html =~ "a &lt; b &amp;&amp; c &gt; d"
    refute html =~ "<script"
  end

  test "never emits raw markup from input" do
    html = NixHighlighter.highlight(~s|"><script>alert("x")</script>|)

    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
    assert html =~ "alert"
  end

  test "highlights line comments to end of line" do
    html = NixHighlighter.highlight("# comment one\n{ pkgs }: pkgs # trailing")

    assert html =~ ~s(<span class="tok-comment"># comment one</span>)
    assert html =~ ~s(<span class="tok-comment"># trailing</span>)
  end

  test "highlights double-quoted strings including interpolation braces" do
    html = NixHighlighter.highlight(~s(name = "api@${port}.service"))

    assert html =~ ~s(<span class="tok-string">"api@${port}.service"</span>)
  end

  test "handles escaped quotes inside strings" do
    html = NixHighlighter.highlight(~s(text = "say \\"hi\\" now"))

    assert html =~ ~s(<span class="tok-string">"say \\"hi\\" now"</span>)
  end

  test "highlights language keywords and booleans" do
    html = NixHighlighter.highlight("rec { let x = true; in if x then null else false }")

    assert html =~ ~s(<span class="tok-keyword">rec</span>)
    assert html =~ ~s(<span class="tok-keyword">true</span>)
    assert html =~ ~s(<span class="tok-keyword">null</span>)
    assert html =~ ~s(<span class="tok-keyword">false</span>)
  end

  test "highlights numbers" do
    html = NixHighlighter.highlight("replicas = 1; cpu = 0.3; port = 4370;")

    assert html =~ ~s(<span class="tok-number">1</span>)
    assert html =~ ~s(<span class="tok-number">0.3</span>)
    assert html =~ ~s(<span class="tok-number">4370</span>)
  end

  test "highlights angle paths" do
    html = NixHighlighter.highlight("pkgs = import <nixpkgs> { };")

    assert html =~ ~s(<span class="tok-path">&lt;nixpkgs&gt;</span>)
  end

  test "does not tokenize identifiers by default" do
    html = NixHighlighter.highlight("{ pkgs, lib, ... }: pkgs.hello")

    refute html =~ "tok-"
  end

  test "mixed content keeps plain segments intact" do
    html =
      NixHighlighter.highlight(
        "# top\n{ config, pkgs, lib, ... }:\n{\n  services.ssh.enable = true; # run\n}\n"
      )

    assert html =~ "{ config, pkgs, lib, ... }:"
    assert html =~ ~s(<span class="tok-keyword">true</span>)
    assert html =~ "services.ssh.enable = "
  end
end
