# Failed GitHub Actions CI Fix Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect failed GitHub Actions workflow runs on open PRs, dispatch Codex to repair safe same-repo branches, and create deterministic blockers for unsafe or unrepaired cases.

**Architecture:** Extend the GitHub PR source with a `GithubFailedCiSource` that emits `ci_fix` work runs. Use Postgres dedupe before dispatch. Add prompt construction for CI context, branch safety checks with `RepoPolicy`, and PR/Linear comments through GitHub and tracker adapters.

**Tech Stack:** Elixir, existing Codex app-server runner, GitHub REST Actions API, Postgres dedupe, ExUnit.

---

## File Structure

- Create: `elixir/lib/symphony_elixir/work_sources/github_failed_ci_source.ex`
- Create: `elixir/lib/symphony_elixir/github/actions_log.ex`
- Modify: `elixir/lib/symphony_elixir/github/client.ex`
- Create: `elixir/lib/symphony_elixir/workflows/ci_fix_prompt.ex`
- Create: `elixir/lib/symphony_elixir/workflows/ci_fix_handoff.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Test: `elixir/test/symphony_elixir/github_failed_ci_source_test.exs`
- Test: `elixir/test/symphony_elixir/ci_fix_prompt_test.exs`
- Test: `elixir/test/symphony_elixir/ci_fix_handoff_test.exs`

## Dedupe Contract

```text
github-ci-fix:<owner>/<repo>:<pr_number>:<head_sha>:<workflow_run_id>
```

Only GitHub Actions workflow runs with `status=completed` and `conclusion=failure` are candidates.

## Tasks

### Task 1: Detect Failed GitHub Actions Runs

**Files:**
- Create: `elixir/lib/symphony_elixir/work_sources/github_failed_ci_source.ex`
- Test: `elixir/test/symphony_elixir/github_failed_ci_source_test.exs`

- [ ] **Step 1: Write candidate test**

```elixir
defmodule SymphonyElixir.GithubFailedCiSourceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Github.{PullRequest, WorkflowRun}
  alias SymphonyElixir.WorkSources.GithubFailedCiSource

  test "emits ci_fix work run for failed github actions run" do
    project = %{
      id: "project-1",
      slug: "portal",
      github_owner: "dezet",
      github_repo: "portal",
      github_base_branch: "develop",
      linear_team_key: "COD",
      config: %{}
    }

    pull_requests = fn _owner, _repo, _opts ->
      {:ok,
       [
         %PullRequest{
           number: 7,
           title: "Fix COD-5",
           body: "Linear: COD-5",
           head_sha: "abc123",
           head_ref: "fix-cod-5",
           head_repo_full_name: "dezet/portal",
           base_ref: "develop",
           base_repo_full_name: "dezet/portal"
         }
       ]}
    end

    workflow_runs = fn _owner, _repo, opts ->
      assert opts[:head_sha] == "abc123"
      {:ok, [%WorkflowRun{id: 123, name: "CI", head_sha: "abc123", status: "completed", conclusion: "failure"}]}
    end

    assert {:ok, [run]} =
             GithubFailedCiSource.fetch_candidates(project,
               list_pull_requests: pull_requests,
               list_workflow_runs: workflow_runs,
               dedupe_seen?: fn _project_id, _key -> false end
             )

    assert run.type == "ci_fix"
    assert run.dedupe_key == "github-ci-fix:dezet/portal:7:abc123:123"
    assert run.github_pr_number == 7
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/github_failed_ci_source_test.exs
```

Expected: missing source.

- [ ] **Step 3: Implement source**

Create the module with `fetch_candidates/2` that:

- lists open PRs,
- lists workflow runs for each `head_sha`,
- filters failed completed runs,
- builds the dedupe key,
- skips keys already seen,
- returns `WorkRun` structs with `type: "ci_fix"`.

Use this exact helper:

```elixir
defp failed_actions_run?(%{status: "completed", conclusion: "failure"}), do: true
defp failed_actions_run?(_run), do: false
```

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/github_failed_ci_source_test.exs
git add elixir/lib/symphony_elixir/work_sources/github_failed_ci_source.ex elixir/test/symphony_elixir/github_failed_ci_source_test.exs
git commit -m "feat(ci): detect failed github actions runs"
```

Expected: tests pass.

### Task 2: Persist Dedupe Claim Before Dispatch

**Files:**
- Modify: `elixir/lib/symphony_elixir/storage.ex`
- Modify: `elixir/lib/symphony_elixir/work_sources/github_failed_ci_source.ex`
- Test: `elixir/test/symphony_elixir/github_failed_ci_source_test.exs`

- [ ] **Step 1: Add duplicate suppression test**

```elixir
test "skips failed run when dedupe key is already processed" do
  project = %{id: "project-1", slug: "portal", github_owner: "dezet", github_repo: "portal", github_base_branch: "develop", linear_team_key: "COD", config: %{}}

  pull_requests = fn _, _, _ ->
    {:ok, [%SymphonyElixir.Github.PullRequest{number: 7, head_sha: "abc123", head_ref: "fix", head_repo_full_name: "dezet/portal", base_ref: "develop", base_repo_full_name: "dezet/portal"}]}
  end

  workflow_runs = fn _, _, _ ->
    {:ok, [%SymphonyElixir.Github.WorkflowRun{id: 123, name: "CI", head_sha: "abc123", status: "completed", conclusion: "failure"}]}
  end

  assert {:ok, []} =
           SymphonyElixir.WorkSources.GithubFailedCiSource.fetch_candidates(project,
             list_pull_requests: pull_requests,
             list_workflow_runs: workflow_runs,
             dedupe_seen?: fn _project_id, _key -> true end
           )
end
```

- [ ] **Step 2: Add storage functions**

Add to `Storage`:

```elixir
@spec dedupe_seen?(binary(), String.t()) :: boolean()
def dedupe_seen?(project_id, key) do
  Repo.exists?(from(d in SymphonyElixir.Storage.DedupeKey, where: d.project_id == ^project_id and d.key == ^key))
end

@spec mark_dedupe_processed(map()) :: {:ok, term()} | {:error, Ecto.Changeset.t()}
def mark_dedupe_processed(attrs) do
  %SymphonyElixir.Storage.DedupeKey{}
  |> SymphonyElixir.Storage.DedupeKey.changeset(stringify_keys(attrs))
  |> Repo.insert(
    on_conflict: :nothing,
    conflict_target: [:project_id, :key],
    returning: true
  )
end
```

- [ ] **Step 3: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/github_failed_ci_source_test.exs
git add elixir/lib/symphony_elixir/storage.ex elixir/lib/symphony_elixir/work_sources/github_failed_ci_source.ex elixir/test/symphony_elixir/github_failed_ci_source_test.exs
git commit -m "feat(ci): dedupe failed ci work"
```

Expected: tests pass.

### Task 3: Fetch Workflow Logs And Build CI Prompt

**Files:**
- Modify: `elixir/lib/symphony_elixir/github/client.ex`
- Create: `elixir/lib/symphony_elixir/github/actions_log.ex`
- Create: `elixir/lib/symphony_elixir/workflows/ci_fix_prompt.ex`
- Test: `elixir/test/symphony_elixir/ci_fix_prompt_test.exs`

- [ ] **Step 1: Write prompt test**

```elixir
defmodule SymphonyElixir.CiFixPromptTest do
  use SymphonyElixir.TestSupport

  test "builds prompt with PR and failing workflow context" do
    run = %SymphonyElixir.WorkRun{
      type: "ci_fix",
      github_owner: "dezet",
      github_repo: "portal",
      github_pr_number: 7,
      github_head_sha: "abc123",
      github_head_ref: "fix-cod-5",
      github_base_ref: "develop",
      payload: %{
        workflow_run: %{id: 123, name: "CI", url: "https://github.com/dezet/portal/actions/runs/123"},
        log_excerpt: "cargo test failed"
      }
    }

    prompt = SymphonyElixir.Workflows.CiFixPrompt.build(run)

    assert prompt =~ "Fix the failed GitHub Actions run"
    assert prompt =~ "PR #7"
    assert prompt =~ "cargo test failed"
    assert prompt =~ "Do not merge the pull request"
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/ci_fix_prompt_test.exs
```

Expected: missing prompt module.

- [ ] **Step 3: Implement client log fetch and prompt builder**

Add `Client.get_workflow_run_logs/4` that follows GitHub's redirect response and stores or returns text. For MVP tests, inject the returned log text.

Create `CiFixPrompt.build/1`:

```elixir
defmodule SymphonyElixir.Workflows.CiFixPrompt do
  @moduledoc """
  Builds the Codex prompt for failed GitHub Actions repair work.
  """

  alias SymphonyElixir.WorkRun

  @spec build(WorkRun.t()) :: String.t()
  def build(%WorkRun{} = run) do
    workflow_run = Map.get(run.payload, :workflow_run) || Map.get(run.payload, "workflow_run") || %{}
    log_excerpt = Map.get(run.payload, :log_excerpt) || Map.get(run.payload, "log_excerpt") || "No log excerpt captured."

    """
    Fix the failed GitHub Actions run for #{run.github_owner}/#{run.github_repo} PR ##{run.github_pr_number}.

    Branch policy:
    - Work only on branch #{run.github_head_ref}.
    - Base branch is #{run.github_base_ref}.
    - Do not merge the pull request.
    - Do not push directly to #{run.github_base_ref}.

    Failing workflow:
    - Name: #{Map.get(workflow_run, :name) || Map.get(workflow_run, "name") || "unknown"}
    - Run ID: #{Map.get(workflow_run, :id) || Map.get(workflow_run, "id") || "unknown"}
    - URL: #{Map.get(workflow_run, :url) || Map.get(workflow_run, "url") || "unknown"}

    Log excerpt:
    #{log_excerpt}

    End state:
    - Push the minimal fix to the PR branch when permitted.
    - Leave a concise handoff summary.
    """
  end
end
```

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/ci_fix_prompt_test.exs
git add elixir/lib/symphony_elixir/github elixir/lib/symphony_elixir/workflows/ci_fix_prompt.ex elixir/test/symphony_elixir/ci_fix_prompt_test.exs
git commit -m "feat(ci): build failed ci repair prompt"
```

Expected: tests pass.

### Task 4: Enforce Safe Push Policy Before Agent Dispatch

**Files:**
- Modify: `elixir/lib/symphony_elixir/work_sources/github_failed_ci_source.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Test: `elixir/test/symphony_elixir/github_failed_ci_source_test.exs`

- [ ] **Step 1: Add unsafe fork test**

```elixir
test "marks fork PR as repair branch required" do
  project = %{
    id: "project-1",
    slug: "portal",
    github_owner: "dezet",
    github_repo: "portal",
    github_base_branch: "develop",
    linear_team_key: "COD",
    config: %{}
  }

  pull_requests = fn _owner, _repo, _opts ->
    {:ok,
     [
       %PullRequest{
         number: 7,
         title: "Fix COD-5",
         body: "Linear: COD-5",
         head_sha: "abc123",
         head_ref: "fix-cod-5",
         head_repo_full_name: "fork/portal",
         base_ref: "develop",
         base_repo_full_name: "dezet/portal"
       }
     ]}
  end

  workflow_runs = fn _owner, _repo, _opts ->
    {:ok, [%WorkflowRun{id: 123, name: "CI", head_sha: "abc123", status: "completed", conclusion: "failure"}]}
  end

  assert {:ok, [run]} =
           GithubFailedCiSource.fetch_candidates(project,
             list_pull_requests: pull_requests,
             list_workflow_runs: workflow_runs,
             dedupe_seen?: fn _project_id, _key -> false end
           )

  assert run.payload.repo_policy == "repair_branch_required"
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/github_failed_ci_source_test.exs
```

Expected: payload lacks `repo_policy`.

- [ ] **Step 3: Add RepoPolicy decision to payload**

When building the `ci_fix` run, call `RepoPolicy.authorize_push/1`.

Store:

```elixir
repo_policy =
  case RepoPolicy.authorize_push(policy_input) do
    :ok -> "direct_push_allowed"
    {:error, :fork_pr_requires_repair_branch} -> "repair_branch_required"
    {:error, reason} -> "blocked:#{reason}"
  end
```

Add `repo_policy` to `run.payload`.

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/github_failed_ci_source_test.exs
git add elixir/lib/symphony_elixir/work_sources/github_failed_ci_source.ex elixir/test/symphony_elixir/github_failed_ci_source_test.exs
git commit -m "feat(ci): classify safe ci repair writes"
```

Expected: tests pass.

### Task 5: Add Handoff Comments For Failed Repair

**Files:**
- Create: `elixir/lib/symphony_elixir/workflows/ci_fix_handoff.ex`
- Modify: `elixir/lib/symphony_elixir/github/client.ex`
- Test: `elixir/test/symphony_elixir/ci_fix_handoff_test.exs`

- [ ] **Step 1: Write handoff test**

```elixir
defmodule SymphonyElixir.CiFixHandoffTest do
  use SymphonyElixir.TestSupport

  test "comments on PR and linked Linear issue when repair is blocked" do
    parent = self()

    github_comment = fn owner, repo, pr_number, body, _opts ->
      send(parent, {:github_comment, owner, repo, pr_number, body})
      :ok
    end

    linear_comment = fn issue_id, body ->
      send(parent, {:linear_comment, issue_id, body})
      :ok
    end

    linear_state = fn issue_id, state ->
      send(parent, {:linear_state, issue_id, state})
      :ok
    end

    run = %SymphonyElixir.WorkRun{
      github_owner: "dezet",
      github_repo: "portal",
      github_pr_number: 7,
      linear_issue_id: "issue-1",
      linear_identifier: "COD-5",
      payload: %{blocker_reason: "fork PR requires repair branch"}
    }

    assert :ok =
             SymphonyElixir.Workflows.CiFixHandoff.blocked(run,
               human_review_state: "Human Review",
               github_comment: github_comment,
               linear_comment: linear_comment,
               linear_state: linear_state
             )

    assert_received {:github_comment, "dezet", "portal", 7, body}
    assert body =~ "fork PR requires repair branch"
    assert_received {:linear_comment, "issue-1", linear_body}
    assert linear_body =~ "fork PR requires repair branch"
    assert_received {:linear_state, "issue-1", "Human Review"}
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/ci_fix_handoff_test.exs
```

Expected: missing handoff module.

- [ ] **Step 3: Implement handoff**

Create a module that:

- posts a PR comment through `Github.Client.create_issue_comment/5`,
- posts a Linear comment when `linear_issue_id` exists,
- moves Linear issue to `Human Review` when linked.

Use body:

```text
Harmony could not complete the failed CI repair automatically.

Reason:
<reason>

The PR remains unmerged for human review.
```

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/ci_fix_handoff_test.exs
git add elixir/lib/symphony_elixir/workflows/ci_fix_handoff.ex elixir/lib/symphony_elixir/github/client.ex elixir/test/symphony_elixir/ci_fix_handoff_test.exs
git commit -m "feat(ci): report failed repair blockers"
```

Expected: tests pass.

### Task 6: Wire CI Fix Work Into Orchestrator

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

- [ ] **Step 1: Add orchestrator source selection test**

Add a test that starts orchestrator with a fake GitHub source returning one `ci_fix` run and fake agent runner recipient that records dispatch. Assert one dispatch occurs and the run is marked running/claimed.

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/orchestrator_status_test.exs --seed 0
```

Expected: no GitHub source dispatch.

- [ ] **Step 3: Add source aggregation**

Refactor `maybe_dispatch/1` to fetch from:

- `LinearIssueSource`,
- `GithubFailedCiSource`.

Add a small private `configured_sources/1` helper that returns the source modules for the active project. Plan 05 appends `GithubReviewRequestSource` to that helper after review-request polling exists.

Keep existing Linear issue path behavior by converting `WorkRun` back to the expected issue payload for `AgentRunner` until a full runner refactor lands.

- [ ] **Step 4: Run focused tests**

```bash
cd elixir
mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/github_failed_ci_source_test.exs
```

Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/lib/symphony_elixir/agent_runner.ex elixir/test/symphony_elixir/orchestrator_status_test.exs
git commit -m "feat(ci): dispatch failed ci repair work"
```

### Task 7: Validate Failed CI Workflow

- [ ] **Step 1: Run targeted tests**

```bash
cd elixir
mix test test/symphony_elixir/github_failed_ci_source_test.exs test/symphony_elixir/ci_fix_prompt_test.exs test/symphony_elixir/ci_fix_handoff_test.exs
```

Expected: all pass.

- [ ] **Step 2: Run full checks**

```bash
cd elixir
mix format --check-formatted
mix specs.check
```

Expected: both exit 0.

- [ ] **Step 3: Manual dry run against a disposable PR**

Run Harmony with a project YAML that points to a disposable repo/PR with a failing GitHub Actions workflow.

Expected:

- one `ci_fix` work run is created,
- dedupe key is persisted,
- repeated polling does not create a duplicate run,
- unsafe branch policy creates a blocker,
- same-repo branch policy dispatches the agent.
