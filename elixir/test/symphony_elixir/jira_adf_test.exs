defmodule SymphonyElixir.JiraAdfTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Jira.Adf

  test "turns paragraphs, lists, code blocks and emoji into safe plain text" do
    document = %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "First"}, %{"type" => "hardBreak"}, %{"type" => "text", "text" => "line"}]},
        %{
          "type" => "bulletList",
          "content" => [
            %{"type" => "listItem", "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "one"}]}]},
            %{"type" => "listItem", "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "two"}]}]}
          ]
        },
        %{"type" => "orderedList", "attrs" => %{"order" => 3}, "content" => [%{"type" => "listItem", "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "three"}]}]}]},
        %{"type" => "codeBlock", "content" => [%{"type" => "text", "text" => "  if x:\n    run()"}]},
        %{"type" => "emoji", "attrs" => %{"shortName" => ":cat:", "text" => "🐈"}}
      ]
    }

    assert Adf.to_text(document) == "First\nline\n• one\n• two\n3. three\n  if x:\n    run()\n🐈"
  end

  test "accepts null descriptions and keeps text from unknown nested nodes" do
    assert Adf.to_text(nil) == ""

    assert Adf.to_text(%{
             "type" => "doc",
             "content" => [%{"type" => "futureNode", "content" => [%{"type" => "text", "text" => "kept"}]}]
           }) == "kept"
  end

  test "truncates on a UTF-8 boundary and marks descriptions exceeding 100 KiB" do
    document = %{
      "type" => "doc",
      "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => String.duplicate("🦊", 30_000)}]}]
    }

    text = Adf.to_text(document)

    assert String.valid?(text)
    assert byte_size(text) <= 100 * 1024
    assert String.ends_with?(text, "[opis skrócono]")
  end
end
