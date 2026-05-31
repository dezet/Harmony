defmodule SymphonyElixir.InlineReviewCommentsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflows.InlineReviewComments

  @diff """
  diff --git a/lib/example.ex b/lib/example.ex
  index 1111111..2222222 100644
  --- a/lib/example.ex
  +++ b/lib/example.ex
  @@ -10,4 +10,5 @@ defmodule Example do
   def existing do
  -  :old
  +  :new
  +  :added
   end
  """

  test "maps comments only to lines present in the current diff" do
    comments = [
      %{path: "lib/example.ex", line: 11, body: "Check the changed return value."},
      %{path: "lib/example.ex", line: 12, body: "Added line needs a test."},
      %{path: "lib/example.ex", line: 20, body: "Outside the diff."}
    ]

    assert InlineReviewComments.map(@diff, comments) == [
             %{path: "lib/example.ex", line: 11, side: "RIGHT", body: "Check the changed return value."},
             %{path: "lib/example.ex", line: 12, side: "RIGHT", body: "Added line needs a test."}
           ]
  end

  test "rejects deleted-side comments" do
    comments = [%{path: "lib/example.ex", line: 11, side: "LEFT", body: "This was deleted."}]

    assert InlineReviewComments.map(@diff, comments) == []
  end

  test "caps inline comments" do
    comments =
      for line <- [11, 12] do
        %{path: "lib/example.ex", line: line, body: "comment #{line}"}
      end

    assert [%{line: 11}] = InlineReviewComments.map(@diff, comments, max_comments: 1)
  end

  test "github client includes inline review comments in review payload" do
    parent = self()

    request_fun = fn request ->
      send(parent, {:request, request})
      {:ok, %{status: 201, body: %{}}}
    end

    comments = [%{path: "lib/example.ex", line: 11, side: "RIGHT", body: "Inline finding."}]

    assert :ok =
             SymphonyElixir.Github.Client.create_pull_request_review(
               "dezet",
               "portal",
               7,
               "Review body",
               request_fun: request_fun,
               comments: comments
             )

    assert_received {:request, request}
    assert request[:json].comments == comments
    assert request[:json].body == "Review body"
    assert request[:json].event == "COMMENT"
  end
end
