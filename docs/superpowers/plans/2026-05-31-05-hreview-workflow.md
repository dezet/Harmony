# HReview Pull Request Review Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect configured `@hreview` PR comment triggers and publish exactly one aggregate formal GitHub PR review per trigger comment, head SHA, and template version.

**Architecture:** Add a `GithubReviewRequestSource` work source that polls PR comments and emits `code_review` work runs. Use Postgres dedupe before dispatch and include a processed marker in the review body. Keep MVP output as one aggregate `COMMENT` review; inline diff comments remain post-MVP.

**Tech Stack:** Elixir, GitHub REST PR comments and reviews APIs, existing Codex runner, Postgres dedupe.

---

## File Structure

- Create: `elixir/lib/symphony_elixir/work_sources/github_review_request_source.ex`
- Create: `elixir/lib/symphony_elixir/workflows/review_prompt.ex`
- Create: `elixir/lib/symphony_elixir/workflows/review_handoff.ex`
- Modify: `elixir/lib/symphony_elixir/github/client.ex`
- Modify: `elixir/lib/symphony_elixir/github/review.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Test: `elixir/test/symphony_elixir/github_review_request_source_test.exs`
- Test: `elixir/test/symphony_elixir/review_prompt_test.exs`
- Test: `elixir/test/symphony_elixir/review_handoff_test.exs`

## Dedupe Contract

```text
github-review:<owner>/<repo>:<pr_number>:<trigger_comment_id>:<head_sha>:<review_template_version>
```

## Tasks

### Task 1: Detect Review Trigger Comments

**Files:**
- Create: `elixir/lib/symphony_elixir/work_sources/github_review_request_source.ex`
- Test: `elixir/test/symphony_elixir/github_review_request_source_test.exs`

- [ ] **Step 1: Write source test**

```elixir
defmodule SymphonyElixir.GithubReviewRequestSourceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.{Comment, PullRequest}
  alias SymphonyElixir.WorkSources.GithubReviewRequestSource

  test "emits code review work for trigger comment" do
    project = %{
      id: "project-1",
      slug: "portal",
      github_owner: "dezet",
      github_repo: "portal",
      github_base_branch: "develop",
      linear_team_key: "COD",
      config: %{"review" => %{"trigger" => "@hreview", "template_version" => 1}}
    }

    list_prs = fn _, _, _ ->
      {:ok, [%PullRequest{number: 7, title: "Review COD-5", body: "COD-5", head_sha: "abc123", head_ref: "feature", base_ref: "develop", head_repo_full_name: "dezet/portal", base_repo_full_name: "dezet/portal"}]}
    end

    list_comments = fn _, _, 7, _ ->
      {:ok, [%Comment{id: 99, body: "@hreview", author: "alice"}]}
    end

    assert {:ok, [run]} =
             GithubReviewRequestSource.fetch_candidates(project,
               list_pull_requests: list_prs,
               list_issue_comments: list_comments,
               dedupe_seen?: fn _, _ -> false end
             )

    assert run.type == "code_review"
    assert run.dedupe_key == "github-review:dezet/portal:7:99:abc123:1"
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/github_review_request_source_test.exs
```

Expected: missing source.

- [ ] **Step 3: Implement source**

Implement `fetch_candidates/2` that:

- reads trigger from project config, default `@hreview`,
- reads template version from project config, default `1`,
- lists open PRs,
- lists PR issue comments,
- matches comments containing trigger,
- builds dedupe key,
- skips processed dedupe keys,
- emits `WorkRun` with `type: "code_review"`.

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/github_review_request_source_test.exs
git add elixir/lib/symphony_elixir/work_sources/github_review_request_source.ex elixir/test/symphony_elixir/github_review_request_source_test.exs
git commit -m "feat(review): detect hreview trigger comments"
```

Expected: tests pass.

### Task 2: Build Configurable Review Prompt

**Files:**
- Create: `elixir/lib/symphony_elixir/workflows/review_prompt.ex`
- Test: `elixir/test/symphony_elixir/review_prompt_test.exs`

- [ ] **Step 1: Write prompt test**

```elixir
defmodule SymphonyElixir.ReviewPromptTest do
  use SymphonyElixir.TestSupport

  test "builds aggregate review prompt" do
    run = %SymphonyElixir.WorkRun{
      type: "code_review",
      github_owner: "dezet",
      github_repo: "portal",
      github_pr_number: 7,
      github_head_sha: "abc123",
      payload: %{
        trigger_comment_id: 99,
        template: "Review correctness, tests, and maintainability."
      }
    }

    prompt = SymphonyElixir.Workflows.ReviewPrompt.build(run)

    assert prompt =~ "Perform a comprehensive code review"
    assert prompt =~ "Review correctness, tests, and maintainability."
    assert prompt =~ "Do not request changes automatically"
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/review_prompt_test.exs
```

Expected: missing prompt module.

- [ ] **Step 3: Implement prompt builder**

Create prompt that requires:

- aggregate review only,
- no inline comments in MVP,
- findings ordered by severity,
- concrete file/line references when the agent can determine them,
- no automatic `REQUEST_CHANGES`,
- final body suitable for GitHub PR review.

- [ ] **Step 4: Run test and commit**

```bash
cd elixir
mix test test/symphony_elixir/review_prompt_test.exs
git add elixir/lib/symphony_elixir/workflows/review_prompt.ex elixir/test/symphony_elixir/review_prompt_test.exs
git commit -m "feat(review): build hreview prompt"
```

Expected: test passes.

### Task 3: Publish Formal PR Review Comment

**Files:**
- Modify: `elixir/lib/symphony_elixir/github/client.ex`
- Create: `elixir/lib/symphony_elixir/workflows/review_handoff.ex`
- Test: `elixir/test/symphony_elixir/review_handoff_test.exs`

- [ ] **Step 1: Write handoff test**

```elixir
defmodule SymphonyElixir.ReviewHandoffTest do
  use SymphonyElixir.TestSupport

  test "posts formal comment review with processed marker" do
    parent = self()

    create_review = fn owner, repo, pr_number, body, opts ->
      send(parent, {:review, owner, repo, pr_number, body, opts})
      :ok
    end

    run = %SymphonyElixir.WorkRun{
      dedupe_key: "github-review:dezet/portal:7:99:abc123:1",
      github_owner: "dezet",
      github_repo: "portal",
      github_pr_number: 7
    }

    assert :ok =
             SymphonyElixir.Workflows.ReviewHandoff.publish(run, "Review body",
               create_review: create_review
             )

    assert_received {:review, "dezet", "portal", 7, body, opts}
    assert body =~ "Review body"
    assert body =~ "harmony-review-processed"
    assert opts[:event] == "COMMENT"
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/review_handoff_test.exs
```

Expected: missing handoff module.

- [ ] **Step 3: Implement client and handoff**

Add `Github.Client.create_pull_request_review/5`:

```elixir
@spec create_pull_request_review(String.t(), String.t(), pos_integer(), String.t(), keyword()) :: :ok | {:error, term()}
def create_pull_request_review(owner, repo, pr_number, body, opts \\ []) do
  request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
  token = Keyword.get(opts, :token) || System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
  event = Keyword.get(opts, :event, "COMMENT")
  url = "#{@api_root}/repos/#{owner}/#{repo}/pulls/#{pr_number}/reviews"

  with {:ok, response} <- request_fun.(method: :post, url: url, json: %{body: body, event: event}, headers: headers(token)),
       :ok <- expect_status(response, 200) do
    :ok
  end
end
```

If GitHub returns 201 for review creation in local manual testing, adjust `expect_status` to accept `[200, 201]` and add a test for both statuses.

Create `ReviewHandoff.publish/3` that appends:

```text
<!-- harmony-review-processed: <dedupe_key> -->
```

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/review_handoff_test.exs
git add elixir/lib/symphony_elixir/github/client.ex elixir/lib/symphony_elixir/workflows/review_handoff.ex elixir/test/symphony_elixir/review_handoff_test.exs
git commit -m "feat(review): publish formal pr review"
```

Expected: tests pass.

### Task 4: Mark Dedupe After Successful Review

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflows/review_handoff.ex`
- Test: `elixir/test/symphony_elixir/review_handoff_test.exs`

- [ ] **Step 1: Add dedupe marking test**

Create a project and run in storage, publish review with fake GitHub function, then assert one `DedupeKey` row exists with the run's dedupe key.

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/review_handoff_test.exs
```

Expected: dedupe row is missing.

- [ ] **Step 3: Mark dedupe after review succeeds**

After `create_review` returns `:ok`, call:

```elixir
Storage.mark_dedupe_processed(%{
  project_id: project_id,
  key: run.dedupe_key,
  scope: "github_review",
  status: "processed",
  metadata: %{"github_pr_number" => run.github_pr_number}
})
```

- [ ] **Step 4: Run test and commit**

```bash
cd elixir
mix test test/symphony_elixir/review_handoff_test.exs
git add elixir/lib/symphony_elixir/workflows/review_handoff.ex elixir/test/symphony_elixir/review_handoff_test.exs
git commit -m "feat(review): persist processed review trigger"
```

Expected: tests pass.

### Task 5: Wire Review Work Into Orchestrator

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

- [ ] **Step 1: Add orchestrator dispatch test**

Start orchestrator with fake `GithubReviewRequestSource` returning one code review run. Assert the run is dispatched once, and a second poll with the same dedupe key does not dispatch again.

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/orchestrator_status_test.exs --seed 0
```

Expected: source is not wired.

- [ ] **Step 3: Add review source to aggregation**

Add `GithubReviewRequestSource` beside Linear and CI sources. Keep dispatch limited by existing concurrency slots.

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/github_review_request_source_test.exs
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/orchestrator_status_test.exs
git commit -m "feat(review): dispatch hreview work"
```

Expected: tests pass.

### Task 6: Validate HReview Workflow

- [ ] **Step 1: Run targeted tests**

```bash
cd elixir
mix test test/symphony_elixir/github_review_request_source_test.exs test/symphony_elixir/review_prompt_test.exs test/symphony_elixir/review_handoff_test.exs
```

Expected: all pass.

- [ ] **Step 2: Manual dry run**

Use a disposable PR, comment `@hreview`, and run one Harmony poll.

Expected:

- one `code_review` work run,
- one GitHub PR review with event `COMMENT`,
- processed marker included,
- repeated polling does not publish another review,
- new head SHA plus new comment can trigger a new review.

