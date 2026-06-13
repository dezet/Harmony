defmodule SymphonyElixir.Forge.GitlabTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Forge.Gitlab

  defp creds(fun), do: %{token: "t", base_url: "https://gl.example.com", request_fun: fun}
  defp ref, do: %{owner: "group", repo: "api", base_url: "https://gl.example.com"}

  test "list_change_requests normalizes MRs to the common shape" do
    fun = fn _ -> {:ok, %{status: 200, body: [%{"iid" => 5, "sha" => "abc", "source_branch" => "f", "target_branch" => "main", "web_url" => "u"}]}} end
    assert {:ok, [%{number: 5, head_sha: "abc", head_ref: "f", base_ref: "main", url: "u"}]} =
             Gitlab.list_change_requests(creds(fun), ref(), [])
  end

  test "list_pipeline_runs maps a failed pipeline to a failure conclusion" do
    fun = fn _ -> {:ok, %{status: 200, body: [%{"id" => 9, "status" => "failed", "sha" => "abc"}]}} end
    assert {:ok, [%{id: 9, status: "completed", conclusion: "failure", head_sha: "abc"}]} =
             Gitlab.list_pipeline_runs(creds(fun), ref(), "abc")
  end

  test "create_comment posts an MR note" do
    fun = fn opts ->
      assert opts[:url] =~ "/merge_requests/5/notes"
      {:ok, %{status: 201, body: %{}}}
    end
    assert :ok = Gitlab.create_comment(creds(fun), ref(), 5, "hello")
  end

  test "list_change_request_comments normalizes notes" do
    fun = fn _ -> {:ok, %{status: 200, body: [%{"id" => 1, "body" => "@hreview", "author" => %{"username" => "dev"}}]}} end
    assert {:ok, [%SymphonyElixir.Gitlab.Note{body: "@hreview", author: "dev"}]} =
             Gitlab.list_change_request_comments(creds(fun), ref(), 5)
  end
end
