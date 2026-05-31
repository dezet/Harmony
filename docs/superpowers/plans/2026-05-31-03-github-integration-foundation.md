# GitHub Integration Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub polling primitives, PR-to-Linear linking, and durable candidate recording without dispatching GitHub work to agents yet.

**Architecture:** Create a small GitHub client around `Req` with injectable request functions for tests. Represent GitHub PRs, comments, and workflow runs with normalized structs. Add work sources that detect candidates and persist `pull_request_links`, `work_events`, and `dedupe_keys`, while leaving actual execution to later workflow plans.

**Tech Stack:** Elixir, Req, GitHub REST API, ExUnit, Postgres storage from Plan 01.

---

## File Structure

- Create: `elixir/lib/symphony_elixir/github/client.ex`
- Create: `elixir/lib/symphony_elixir/github/pull_request.ex`
- Create: `elixir/lib/symphony_elixir/github/comment.ex`
- Create: `elixir/lib/symphony_elixir/github/workflow_run.ex`
- Create: `elixir/lib/symphony_elixir/github/review.ex`
- Create: `elixir/lib/symphony_elixir/github/link_resolver.ex`
- Create: `elixir/lib/symphony_elixir/work_sources/github_pr_source.ex`
- Modify: `elixir/lib/symphony_elixir/storage.ex`
- Test: `elixir/test/symphony_elixir/github_client_test.exs`
- Test: `elixir/test/symphony_elixir/github_link_resolver_test.exs`
- Test: `elixir/test/symphony_elixir/github_work_source_test.exs`
- Modify: `elixir/README.md`

## API References

- Pulls: `GET /repos/{owner}/{repo}/pulls`
- Issue comments on PRs: `GET /repos/{owner}/{repo}/issues/{issue_number}/comments`
- Actions workflow runs: `GET /repos/{owner}/{repo}/actions/runs`
- Pull request review creation: later plans use `POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews`

## Tasks

### Task 1: Add GitHub Client Auth And Open PR Listing

**Files:**
- Create: `elixir/lib/symphony_elixir/github/client.ex`
- Create: `elixir/lib/symphony_elixir/github/pull_request.ex`
- Test: `elixir/test/symphony_elixir/github_client_test.exs`

- [ ] **Step 1: Write client test**

```elixir
defmodule SymphonyElixir.GithubClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.Client

  test "lists open pull requests with normalized fields" do
    request_fun = fn opts ->
      send(self(), {:github_request, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: [
           %{
             "number" => 7,
             "title" => "Fix CI",
             "html_url" => "https://github.com/dezet/portal/pull/7",
             "head" => %{
               "sha" => "abc123",
               "ref" => "fix-ci",
               "repo" => %{"full_name" => "dezet/portal"}
             },
             "base" => %{
               "ref" => "develop",
               "repo" => %{"full_name" => "dezet/portal"}
             },
             "body" => "Linear: COD-5"
           }
         ]
       }}
    end

    assert {:ok, [pr]} =
             Client.list_open_pull_requests("dezet", "portal",
               token: "token",
               request_fun: request_fun
             )

    assert pr.number == 7
    assert pr.head_sha == "abc123"
    assert pr.head_repo_full_name == "dezet/portal"
    assert pr.base_ref == "develop"

    assert_received {:github_request, opts}
    assert opts[:method] == :get
    assert opts[:url] =~ "/repos/dezet/portal/pulls"
    assert {"authorization", "Bearer token"} in opts[:headers]
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/github_client_test.exs
```

Expected: missing `SymphonyElixir.Github.Client`.

- [ ] **Step 3: Implement PR struct and client**

Create `Github.PullRequest`:

```elixir
defmodule SymphonyElixir.Github.PullRequest do
  @moduledoc """
  Normalized GitHub pull request data used by Harmony work sources.
  """

  defstruct [
    :number,
    :title,
    :body,
    :url,
    :head_sha,
    :head_ref,
    :head_repo_full_name,
    :base_ref,
    :base_repo_full_name
  ]

  @type t :: %__MODULE__{}

  @spec from_api(map()) :: t()
  def from_api(raw) when is_map(raw) do
    %__MODULE__{
      number: raw["number"],
      title: raw["title"],
      body: raw["body"],
      url: raw["html_url"],
      head_sha: get_in(raw, ["head", "sha"]),
      head_ref: get_in(raw, ["head", "ref"]),
      head_repo_full_name: get_in(raw, ["head", "repo", "full_name"]),
      base_ref: get_in(raw, ["base", "ref"]),
      base_repo_full_name: get_in(raw, ["base", "repo", "full_name"])
    }
  end
end
```

Create `Github.Client`:

```elixir
defmodule SymphonyElixir.Github.Client do
  @moduledoc """
  Minimal GitHub REST client for Harmony PR polling.
  """

  alias SymphonyElixir.Github.PullRequest

  @api_root "https://api.github.com"

  @spec list_open_pull_requests(String.t(), String.t(), keyword()) :: {:ok, [PullRequest.t()]} | {:error, term()}
  def list_open_pull_requests(owner, repo, opts \\ [])
      when is_binary(owner) and is_binary(repo) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    token = Keyword.get(opts, :token) || System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
    url = "#{@api_root}/repos/#{owner}/#{repo}/pulls"

    with {:ok, response} <-
           request_fun.(
             method: :get,
             url: url,
             params: [state: "open", per_page: 100],
             headers: headers(token)
           ),
         :ok <- expect_status(response, 200) do
      {:ok, Enum.map(response.body, &PullRequest.from_api/1)}
    end
  end

  defp headers(token) when is_binary(token) and token != "" do
    [{"authorization", "Bearer #{token}"}, {"accept", "application/vnd.github+json"}]
  end

  defp headers(_), do: [{"accept", "application/vnd.github+json"}]

  defp expect_status(%{status: status}, expected) when status == expected, do: :ok
  defp expect_status(%{status: status, body: body}, _expected), do: {:error, {:github_status, status, body}}
end
```

- [ ] **Step 4: Run test and commit**

```bash
cd elixir
mix test test/symphony_elixir/github_client_test.exs
git add elixir/lib/symphony_elixir/github elixir/test/symphony_elixir/github_client_test.exs
git commit -m "feat(github): list open pull requests"
```

Expected: test passes before commit.

### Task 2: Add PR Comment And Workflow Run Client Calls

**Files:**
- Modify: `elixir/lib/symphony_elixir/github/client.ex`
- Create: `elixir/lib/symphony_elixir/github/comment.ex`
- Create: `elixir/lib/symphony_elixir/github/workflow_run.ex`
- Test: `elixir/test/symphony_elixir/github_client_test.exs`

- [ ] **Step 1: Add tests for comments and workflow runs**

```elixir
test "lists PR comments" do
  request_fun = fn opts ->
    assert opts[:url] =~ "/repos/dezet/portal/issues/7/comments"
    {:ok, %Req.Response{status: 200, body: [%{"id" => 99, "body" => "@hreview please", "user" => %{"login" => "alice"}}]}}
  end

  assert {:ok, [comment]} =
           Client.list_issue_comments("dezet", "portal", 7, token: "token", request_fun: request_fun)

  assert comment.id == 99
  assert comment.body == "@hreview please"
end

test "lists workflow runs for a head sha" do
  request_fun = fn opts ->
    assert opts[:url] =~ "/repos/dezet/portal/actions/runs"
    assert opts[:params][:head_sha] == "abc123"

    {:ok,
     %Req.Response{
       status: 200,
       body: %{
         "workflow_runs" => [
           %{"id" => 123, "name" => "CI", "head_sha" => "abc123", "status" => "completed", "conclusion" => "failure", "html_url" => "https://github.com/dezet/portal/actions/runs/123"}
         ]
       }
     }}
  end

  assert {:ok, [run]} =
           Client.list_workflow_runs("dezet", "portal", head_sha: "abc123", token: "token", request_fun: request_fun)

  assert run.id == 123
  assert run.conclusion == "failure"
end
```

- [ ] **Step 2: Run failing tests**

```bash
cd elixir
mix test test/symphony_elixir/github_client_test.exs
```

Expected: missing client functions.

- [ ] **Step 3: Implement structs and functions**

Add `Github.Comment.from_api/1` and `Github.WorkflowRun.from_api/1` with fields used by tests.

Add to client:

```elixir
@spec list_issue_comments(String.t(), String.t(), pos_integer(), keyword()) :: {:ok, [Comment.t()]} | {:error, term()}
def list_issue_comments(owner, repo, issue_number, opts \\ []) do
  request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
  token = Keyword.get(opts, :token) || System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
  url = "#{@api_root}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments"

  with {:ok, response} <- request_fun.(method: :get, url: url, params: [per_page: 100], headers: headers(token)),
       :ok <- expect_status(response, 200) do
    {:ok, Enum.map(response.body, &Comment.from_api/1)}
  end
end

@spec list_workflow_runs(String.t(), String.t(), keyword()) :: {:ok, [WorkflowRun.t()]} | {:error, term()}
def list_workflow_runs(owner, repo, opts \\ []) do
  request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
  token = Keyword.get(opts, :token) || System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
  url = "#{@api_root}/repos/#{owner}/#{repo}/actions/runs"

  params =
    [per_page: 100]
    |> Keyword.merge(if Keyword.get(opts, :head_sha), do: [head_sha: Keyword.fetch!(opts, :head_sha)], else: [])

  with {:ok, response} <- request_fun.(method: :get, url: url, params: params, headers: headers(token)),
       :ok <- expect_status(response, 200) do
    {:ok, response.body["workflow_runs"] |> List.wrap() |> Enum.map(&WorkflowRun.from_api/1)}
  end
end
```

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/github_client_test.exs
git add elixir/lib/symphony_elixir/github elixir/test/symphony_elixir/github_client_test.exs
git commit -m "feat(github): fetch comments and workflow runs"
```

Expected: tests pass.

### Task 3: Add PR-To-Linear Link Resolver

**Files:**
- Create: `elixir/lib/symphony_elixir/github/link_resolver.ex`
- Test: `elixir/test/symphony_elixir/github_link_resolver_test.exs`

- [ ] **Step 1: Write resolver tests**

```elixir
defmodule SymphonyElixir.GithubLinkResolverTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.LinkResolver
  alias SymphonyElixir.Github.PullRequest

  test "finds linear URL and issue identifier in PR body and branch" do
    pr = %PullRequest{
      number: 1,
      body: "Linear: https://linear.app/dezet/issue/COD-5/smoke-test",
      head_ref: "harmony-smoke-test-cod-5",
      title: "Smoke"
    }

    assert %{identifier: "COD-5", url: "https://linear.app/dezet/issue/COD-5/smoke-test"} =
             LinkResolver.resolve(pr, team_keys: ["COD"])
  end

  test "returns nil when no configured team key is present" do
    pr = %PullRequest{number: 2, body: "No issue", head_ref: "feature/no-issue", title: "No issue"}
    assert is_nil(LinkResolver.resolve(pr, team_keys: ["COD"]))
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/github_link_resolver_test.exs
```

Expected: missing resolver.

- [ ] **Step 3: Implement resolver**

```elixir
defmodule SymphonyElixir.Github.LinkResolver do
  @moduledoc """
  Resolves Linear issue references from GitHub PR metadata.
  """

  @linear_url_regex ~r"https://linear\.app/[^\s)]+/issue/([A-Z][A-Z0-9]+-\d+)/[^\s)]*"

  @spec resolve(map(), keyword()) :: map() | nil
  def resolve(pr, opts \\ []) when is_map(pr) do
    team_keys = Keyword.get(opts, :team_keys, [])
    text = Enum.join([Map.get(pr, :body), Map.get(pr, :head_ref), Map.get(pr, :title)], "\n")

    url_match = Regex.run(@linear_url_regex, text)
    identifier = identifier_from_url_match(url_match) || identifier_from_text(text, team_keys)

    case identifier do
      nil -> nil
      value -> %{identifier: value, url: url_from_match(url_match)}
    end
  end

  defp identifier_from_url_match([_url, identifier]), do: identifier
  defp identifier_from_url_match(_), do: nil

  defp url_from_match([url, _identifier]), do: url
  defp url_from_match(_), do: nil

  defp identifier_from_text(text, team_keys) do
    team_keys
    |> Enum.map(&Regex.escape/1)
    |> case do
      [] -> nil
      escaped -> Regex.run(~r"\b(#{Enum.join(escaped, "|")})-\d+\b"i, text)
    end
    |> case do
      [identifier | _] -> String.upcase(identifier)
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/github_link_resolver_test.exs
git add elixir/lib/symphony_elixir/github/link_resolver.ex elixir/test/symphony_elixir/github_link_resolver_test.exs
git commit -m "feat(github): resolve linear links from pull requests"
```

Expected: tests pass.

### Task 4: Add GitHub PR Candidate Source Without Dispatch

**Files:**
- Create: `elixir/lib/symphony_elixir/work_sources/github_pr_source.ex`
- Modify: `elixir/lib/symphony_elixir/storage.ex`
- Test: `elixir/test/symphony_elixir/github_work_source_test.exs`

- [ ] **Step 1: Write durable candidate test**

```elixir
defmodule SymphonyElixir.GithubWorkSourceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.PullRequest
  alias SymphonyElixir.WorkSources.GithubPrSource

  test "records open PR candidates and resolved linear links" do
    {:ok, project} =
      SymphonyElixir.Storage.upsert_project(%{
        slug: "portal",
        github_owner: "dezet",
        github_repo: "portal",
        github_base_branch: "develop",
        linear_project_slug: "portal-linear",
        linear_team_key: "COD",
        linear_human_review_state: "Human Review",
        config_version: 1,
        config: %{}
      })

    list_prs = fn _owner, _repo, _opts ->
      {:ok,
       [
         %PullRequest{
           number: 7,
           title: "Fix COD-5",
           body: "Linear: https://linear.app/dezet/issue/COD-5/smoke-test",
           head_sha: "abc123",
           head_ref: "fix-cod-5",
           head_repo_full_name: "dezet/portal",
           base_ref: "develop",
           base_repo_full_name: "dezet/portal"
         }
       ]}
    end

    assert {:ok, [candidate]} = GithubPrSource.fetch_candidates(project, list_pull_requests: list_prs)
    assert candidate.github_pr_number == 7
    assert candidate.linear_identifier == "COD-5"
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/github_work_source_test.exs
```

Expected: missing `GithubPrSource`.

- [ ] **Step 3: Implement source and storage helper**

Add `Storage.upsert_pull_request_link/1`.

Create source:

```elixir
defmodule SymphonyElixir.WorkSources.GithubPrSource do
  @moduledoc """
  Polls open GitHub PRs and records durable PR metadata.
  """

  alias SymphonyElixir.{Github, Storage, WorkRun}

  @spec fetch_candidates(term(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    list_pull_requests = Keyword.get(opts, :list_pull_requests, &Github.Client.list_open_pull_requests/3)

    with {:ok, prs} <- list_pull_requests.(project.github_owner, project.github_repo, []) do
      runs =
        Enum.map(prs, fn pr ->
          link = Github.LinkResolver.resolve(pr, team_keys: [project.linear_team_key])
          persist_link(project, pr, link)
          pr_to_candidate(project, pr, link)
        end)

      {:ok, runs}
    end
  end

  defp persist_link(project, pr, link) do
    Storage.upsert_pull_request_link(%{
      project_id: project.id,
      github_owner: project.github_owner,
      github_repo: project.github_repo,
      github_pr_number: pr.number,
      github_head_sha: pr.head_sha,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      metadata: %{"title" => pr.title}
    })
  end

  defp pr_to_candidate(project, pr, link) do
    %WorkRun{
      project_slug: project.slug,
      type: "github_pr_observed",
      status: "observed",
      github_owner: project.github_owner,
      github_repo: project.github_repo,
      github_pr_number: pr.number,
      github_head_sha: pr.head_sha,
      github_head_ref: pr.head_ref,
      github_base_ref: pr.base_ref,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      agent_backend: "codex",
      payload: %{pull_request: pr}
    }
  end
end
```

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/github_work_source_test.exs
git add elixir/lib/symphony_elixir/work_sources/github_pr_source.ex elixir/lib/symphony_elixir/storage.ex elixir/test/symphony_elixir/github_work_source_test.exs
git commit -m "feat(github): record pull request candidates"
```

Expected: tests pass.

### Task 5: Validate GitHub Foundation

- [ ] **Step 1: Run targeted tests**

```bash
cd elixir
mix test test/symphony_elixir/github_client_test.exs test/symphony_elixir/github_link_resolver_test.exs test/symphony_elixir/github_work_source_test.exs
```

Expected: all pass.

- [ ] **Step 2: Run formatting and specs**

```bash
cd elixir
mix format --check-formatted
mix specs.check
```

Expected: both exit 0.
