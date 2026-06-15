defmodule SymphonyElixir.GitlabReviewThreadsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Forge.Gitlab

  @discussions [
    %{
      "id" => "d1",
      "notes" => [
        %{
          "id" => 11,
          "body" => "rename",
          "resolvable" => true,
          "resolved" => false,
          "author" => %{"username" => "alice"},
          "created_at" => "2026-06-14T10:00:00Z",
          "position" => %{"new_path" => "lib/a.ex", "new_line" => 12}
        }
      ]
    }
  ]

  test "list_review_threads normalizes discussions" do
    request_fun = fn _req -> {:ok, %Req.Response{status: 200, body: @discussions}} end
    creds = %{token: "t", base_url: nil, request_fun: request_fun}

    assert {:ok, [thread]} = Gitlab.list_review_threads(creds, %{owner: "grp", repo: "proj"}, 7)
    assert thread.id == "d1"
    assert thread.resolved == false
    assert thread.path == "lib/a.ex"
    assert thread.author == "alice"
  end

  test "resolve_review_thread PUTs resolved=true on the discussion" do
    test_pid = self()
    # The GitLab client invokes request_fun with a keyword list (not a %Req.Request{}),
    # matching the existing client idiom (see Gitlab.Client / gitlab/client_test.exs).
    request_fun = fn req ->
      send(test_pid, {:method_url, req[:method], req[:url]})
      {:ok, %Req.Response{status: 200, body: %{}}}
    end

    creds = %{token: "t", base_url: nil, request_fun: request_fun}
    assert :ok = Gitlab.resolve_review_thread(creds, %{owner: "grp", repo: "proj"}, 7, "d1")
    assert_received {:method_url, :put, url}
    assert url =~ "/discussions/d1"
  end
end
