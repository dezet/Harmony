defmodule SymphonyElixir.Gitlab.ClientTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Gitlab.Client

  test "list_open_merge_requests hits the encoded project path and normalizes" do
    fake = fn opts ->
      assert opts[:method] == :get
      assert opts[:url] == "https://gl.example.com/api/v4/projects/group%2Fapi/merge_requests"
      assert {"private-token", "t"} in opts[:headers]
      assert opts[:params][:state] == "opened"
      {:ok, %{status: 200, body: [%{"iid" => 5, "sha" => "abc", "source_branch" => "f", "target_branch" => "main", "title" => "T"}]}}
    end

    assert {:ok, [%{number: 5, head_sha: "abc"}]} =
             Client.list_open_merge_requests("group", "api", token: "t", base_url: "https://gl.example.com", request_fun: fake)
  end

  test "get_job_trace returns the raw body" do
    fake = fn opts ->
      assert opts[:url] == "https://gitlab.com/api/v4/projects/g%2Fa/jobs/3/trace"
      {:ok, %{status: 200, body: "boom\nfailed"}}
    end

    assert {:ok, "boom\nfailed"} = Client.get_job_trace("g", "a", 3, request_fun: fake)
  end

  test "create_merge_request_note posts the body" do
    fake = fn opts ->
      assert opts[:method] == :post
      assert opts[:url] == "https://gitlab.com/api/v4/projects/g%2Fa/merge_requests/5/notes"
      assert opts[:json] == %{body: "hi"}
      {:ok, %{status: 201, body: %{}}}
    end

    assert :ok = Client.create_merge_request_note("g", "a", 5, "hi", request_fun: fake)
  end
end
