# Runtime Policy And WorkRun Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Linear issue execution onto a normalized `WorkRun` model and enforce PR-only, Human Review, blocker, and base-branch safety policy in runtime code.

**Architecture:** Add `WorkSource` and `WorkRun` structs beside the existing orchestrator before changing dispatch internals. Keep the current Linear issue path working, then route it through a `LinearIssueSource` and `RuntimePolicy` layer. Persist durable blocker/handoff events through the storage context created in Plan 01.

**Tech Stack:** Elixir/OTP GenServer, existing Linear tracker adapter, Ecto-backed storage, ExUnit.

---

## File Structure

- Create: `elixir/lib/symphony_elixir/work_run.ex`
- Create: `elixir/lib/symphony_elixir/work_source.ex`
- Create: `elixir/lib/symphony_elixir/work_sources/linear_issue_source.ex`
- Create: `elixir/lib/symphony_elixir/runtime_policy.ex`
- Create: `elixir/lib/symphony_elixir/runtime_policy/blocker.ex`
- Create: `elixir/lib/symphony_elixir/runtime_policy/repo_policy.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/lib/symphony_elixir/prompt_builder.ex`
- Modify: `elixir/lib/symphony_elixir/tracker.ex`
- Modify: `elixir/lib/symphony_elixir/linear/adapter.ex`
- Test: `elixir/test/symphony_elixir/work_run_test.exs`
- Test: `elixir/test/symphony_elixir/runtime_policy_test.exs`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

## Runtime Contract

`WorkRun` is the unit passed to scheduling and execution. Linear issues are represented as
`type: "implementation"` work runs. GitHub-driven work will reuse the same model in later plans.

Status values:

- `queued`
- `running`
- `blocked`
- `completed`
- `handoff`
- `failed`

Handoff means Harmony reached PR plus Human Review. It does not mean merged or Linear Done.

## Tasks

### Task 1: Add WorkRun Struct And Source Behavior

**Files:**
- Create: `elixir/lib/symphony_elixir/work_run.ex`
- Create: `elixir/lib/symphony_elixir/work_source.ex`
- Test: `elixir/test/symphony_elixir/work_run_test.exs`

- [ ] **Step 1: Write failing WorkRun tests**

```elixir
defmodule SymphonyElixir.WorkRunTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.WorkRun
  alias SymphonyElixir.Linear.Issue

  test "builds implementation work run from linear issue" do
    issue = %Issue{
      id: "issue-1",
      identifier: "COD-5",
      title: "Smoke test",
      description: "Create a proof of life",
      state: "Todo",
      url: "https://linear.app/dezet/issue/COD-5/smoke-test",
      project_id: "project-1",
      project_name: "Portal",
      project_slug: "portal"
    }

    run = WorkRun.from_linear_issue(issue, project_slug: "portal", base_branch: "develop")

    assert run.type == "implementation"
    assert run.dedupe_key == "linear:issue-1"
    assert run.linear_identifier == "COD-5"
    assert run.github_base_ref == "develop"
    assert run.payload.issue.title == "Smoke test"
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/work_run_test.exs
```

Expected: compile failure for missing `SymphonyElixir.WorkRun`.

- [ ] **Step 3: Implement WorkRun and behavior**

Create `elixir/lib/symphony_elixir/work_run.ex`:

```elixir
defmodule SymphonyElixir.WorkRun do
  @moduledoc """
  Normalized unit of work dispatched by the orchestrator.
  """

  alias SymphonyElixir.Linear.Issue

  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :project_slug,
    :type,
    :status,
    :dedupe_key,
    :github_owner,
    :github_repo,
    :github_pr_number,
    :github_head_sha,
    :github_head_ref,
    :github_base_ref,
    :linear_issue_id,
    :linear_identifier,
    :linear_url,
    :agent_backend,
    payload: %{},
    required_evidence: []
  ]

  @spec from_linear_issue(Issue.t(), keyword()) :: t()
  def from_linear_issue(%Issue{} = issue, opts) when is_list(opts) do
    %__MODULE__{
      project_slug: Keyword.get(opts, :project_slug) || issue.project_slug,
      type: "implementation",
      status: "queued",
      dedupe_key: "linear:#{issue.id}",
      github_base_ref: Keyword.get(opts, :base_branch),
      linear_issue_id: issue.id,
      linear_identifier: issue.identifier,
      linear_url: issue.url,
      agent_backend: "codex",
      payload: %{issue: issue}
    }
  end
end
```

Create `elixir/lib/symphony_elixir/work_source.ex`:

```elixir
defmodule SymphonyElixir.WorkSource do
  @moduledoc """
  Behavior for polling work candidates from external systems.
  """

  @callback fetch_candidates(keyword()) :: {:ok, [SymphonyElixir.WorkRun.t()]} | {:error, term()}
end
```

- [ ] **Step 4: Run test**

```bash
cd elixir
mix test test/symphony_elixir/work_run_test.exs
```

Expected: test passes.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/work_run.ex elixir/lib/symphony_elixir/work_source.ex elixir/test/symphony_elixir/work_run_test.exs
git commit -m "feat(runtime): introduce work run model"
```

### Task 2: Add LinearIssueSource

**Files:**
- Create: `elixir/lib/symphony_elixir/work_sources/linear_issue_source.ex`
- Test: `elixir/test/symphony_elixir/work_run_test.exs`

- [ ] **Step 1: Add source test**

```elixir
test "linear issue source maps tracker issues to work runs" do
  issue = %Issue{id: "issue-1", identifier: "COD-5", title: "Smoke", state: "Todo", project_slug: "portal"}

  fetcher = fn -> {:ok, [issue]} end

  assert {:ok, [run]} =
           SymphonyElixir.WorkSources.LinearIssueSource.fetch_candidates(
             issue_fetcher: fetcher,
             project_slug: "portal",
             base_branch: "develop"
           )

  assert run.type == "implementation"
  assert run.linear_identifier == "COD-5"
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/work_run_test.exs
```

Expected: compile failure for missing source module.

- [ ] **Step 3: Implement LinearIssueSource**

```elixir
defmodule SymphonyElixir.WorkSources.LinearIssueSource do
  @moduledoc """
  Converts tracker Linear issues into implementation work runs.
  """

  @behaviour SymphonyElixir.WorkSource

  alias SymphonyElixir.{Tracker, WorkRun}

  @impl true
  def fetch_candidates(opts \\ []) do
    issue_fetcher = Keyword.get(opts, :issue_fetcher, &Tracker.fetch_candidate_issues/0)

    with {:ok, issues} <- issue_fetcher.() do
      runs =
        Enum.map(issues, fn issue ->
          WorkRun.from_linear_issue(issue,
            project_slug: Keyword.get(opts, :project_slug),
            base_branch: Keyword.get(opts, :base_branch)
          )
        end)

      {:ok, runs}
    end
  end
end
```

- [ ] **Step 4: Run test and commit**

```bash
cd elixir
mix test test/symphony_elixir/work_run_test.exs
git add elixir/lib/symphony_elixir/work_sources/linear_issue_source.ex elixir/test/symphony_elixir/work_run_test.exs
git commit -m "feat(runtime): add linear issue work source"
```

Expected: tests pass before commit.

### Task 3: Add RuntimePolicy Branch And Handoff Checks

**Files:**
- Create: `elixir/lib/symphony_elixir/runtime_policy.ex`
- Create: `elixir/lib/symphony_elixir/runtime_policy/repo_policy.ex`
- Test: `elixir/test/symphony_elixir/runtime_policy_test.exs`

- [ ] **Step 1: Write branch policy tests**

```elixir
defmodule SymphonyElixir.RuntimePolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RuntimePolicy.RepoPolicy

  test "rejects push to base branch" do
    assert {:error, :base_branch_push_forbidden} =
             RepoPolicy.authorize_push(%{
               head_repo_full_name: "dezet/portal",
               base_repo_full_name: "dezet/portal",
               head_ref: "develop",
               base_ref: "develop",
               protected_branches: ["develop"]
             })
  end

  test "allows same repo feature branch push" do
    assert :ok =
             RepoPolicy.authorize_push(%{
               head_repo_full_name: "dezet/portal",
               base_repo_full_name: "dezet/portal",
               head_ref: "harmony-smoke-test-cod-5",
               base_ref: "develop",
               protected_branches: ["develop"]
             })
  end

  test "routes forks to repair branch flow" do
    assert {:error, :fork_pr_requires_repair_branch} =
             RepoPolicy.authorize_push(%{
               head_repo_full_name: "contrib/portal",
               base_repo_full_name: "dezet/portal",
               head_ref: "fix-ci",
               base_ref: "develop",
               protected_branches: ["develop"]
             })
  end
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/runtime_policy_test.exs
```

Expected: compile failure for missing `RepoPolicy`.

- [ ] **Step 3: Implement RepoPolicy**

```elixir
defmodule SymphonyElixir.RuntimePolicy.RepoPolicy do
  @moduledoc """
  Repository safety policy for PR branch writes.
  """

  @spec authorize_push(map()) :: :ok | {:error, atom()}
  def authorize_push(%{} = pr) do
    head_repo = Map.get(pr, :head_repo_full_name)
    base_repo = Map.get(pr, :base_repo_full_name)
    head_ref = Map.get(pr, :head_ref)
    base_ref = Map.get(pr, :base_ref)
    protected = Map.get(pr, :protected_branches, [])

    cond do
      head_repo != base_repo ->
        {:error, :fork_pr_requires_repair_branch}

      head_ref == base_ref ->
        {:error, :base_branch_push_forbidden}

      head_ref in protected ->
        {:error, :protected_branch_push_forbidden}

      true ->
        :ok
    end
  end
end
```

- [ ] **Step 4: Run policy tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/runtime_policy_test.exs
git add elixir/lib/symphony_elixir/runtime_policy elixir/test/symphony_elixir/runtime_policy_test.exs
git commit -m "feat(policy): add repository push guard"
```

Expected: policy tests pass.

### Task 4: Add Durable Blocker Helper

**Files:**
- Create: `elixir/lib/symphony_elixir/runtime_policy/blocker.ex`
- Modify: `elixir/lib/symphony_elixir/storage.ex`
- Test: `elixir/test/symphony_elixir/runtime_policy_test.exs`

- [ ] **Step 1: Add blocker test**

```elixir
test "records blocker and suppresses duplicate open blocker" do
  {:ok, project} =
    SymphonyElixir.Storage.upsert_project(%{
      slug: "portal",
      github_owner: "dezet",
      github_repo: "portal",
      github_base_branch: "develop",
      linear_project_slug: "portal-linear",
      linear_human_review_state: "Human Review",
      config_version: 1,
      config: %{}
    })

  attrs = %{
    project_id: project.id,
    target_type: "linear_issue",
    target_id: "issue-1",
    reason: "missing acceptance criteria",
    metadata: %{"identifier" => "COD-5"}
  }

  assert {:ok, first} = SymphonyElixir.RuntimePolicy.Blocker.record(attrs)
  assert {:ok, second} = SymphonyElixir.RuntimePolicy.Blocker.record(attrs)
  assert first.id == second.id
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/runtime_policy_test.exs
```

Expected: missing blocker helper.

- [ ] **Step 3: Implement storage function and blocker helper**

Add to `Storage`:

```elixir
@spec upsert_open_blocker(map()) :: {:ok, SymphonyElixir.Storage.Blocker.t()} | {:error, Ecto.Changeset.t()}
def upsert_open_blocker(attrs) when is_map(attrs) do
  attrs = stringify_keys(attrs)

  %SymphonyElixir.Storage.Blocker{}
  |> SymphonyElixir.Storage.Blocker.changeset(Map.put(attrs, "status", "open"))
  |> Repo.insert(
    on_conflict: {:replace, [:reason, :metadata, :updated_at]},
    conflict_target: [:project_id, :target_type, :target_id, :status],
    returning: true
  )
end
```

Add a partial unique index in a new migration:

```elixir
create(
  unique_index(:blockers, [:project_id, :target_type, :target_id, :status],
    where: "status = 'open'",
    name: :blockers_unique_open_target
  )
)
```

Create `RuntimePolicy.Blocker`:

```elixir
defmodule SymphonyElixir.RuntimePolicy.Blocker do
  @moduledoc """
  Durable blocker recording helpers.
  """

  alias SymphonyElixir.Storage

  @spec record(map()) :: {:ok, term()} | {:error, term()}
  def record(attrs) when is_map(attrs), do: Storage.upsert_open_blocker(attrs)
end
```

- [ ] **Step 4: Run migration and test**

```bash
cd elixir
MIX_ENV=test mix ecto.migrate
mix test test/symphony_elixir/runtime_policy_test.exs
```

Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add elixir/priv/repo/migrations elixir/lib/symphony_elixir/storage.ex elixir/lib/symphony_elixir/runtime_policy/blocker.ex elixir/test/symphony_elixir/runtime_policy_test.exs
git commit -m "feat(policy): persist runtime blockers"
```

### Task 5: Integrate Blocker Policy Into Existing Orchestrator

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

- [ ] **Step 1: Add regression test for durable input blocker**

Extend the existing input-required blocker tests by asserting a durable blocker exists after the orchestrator blocks:

```elixir
assert [%SymphonyElixir.Storage.Blocker{target_id: ^issue_id, reason: "codex turn requires operator input"}] =
         SymphonyElixir.Repo.all(SymphonyElixir.Storage.Blocker)
```

- [ ] **Step 2: Run failing orchestrator test**

```bash
cd elixir
mix test test/symphony_elixir/orchestrator_status_test.exs --seed 0
```

Expected: the new durable blocker assertion fails because the orchestrator only stores blocker state in memory.

- [ ] **Step 3: Record durable blocker in `block_issue_from_entry/4`**

In `Orchestrator.block_issue_from_entry/4`, after building `blocked_entry`, call:

```elixir
_ =
  SymphonyElixir.RuntimePolicy.Blocker.record(%{
    project_id: Map.get(running_entry, :storage_project_id),
    work_run_id: Map.get(running_entry, :storage_work_run_id),
    target_type: "linear_issue",
    target_id: issue_id,
    reason: error,
    metadata: %{
      "identifier" => Map.get(running_entry, :identifier, issue_id),
      "session_id" => running_entry_session_id(running_entry),
      "worker_host" => Map.get(running_entry, :worker_host),
      "workspace_path" => Map.get(running_entry, :workspace_path)
    }
  })
```

If `storage_project_id` is not available for legacy in-memory tests, use a helper that creates or fetches a synthetic `"legacy"` project in test/dev and logs a warning in production. Keep this helper private to the orchestrator until all dispatch paths pass a real project id.

- [ ] **Step 4: Run focused test**

```bash
cd elixir
mix test test/symphony_elixir/orchestrator_status_test.exs --seed 0
```

Expected: test passes.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/orchestrator_status_test.exs
git commit -m "feat(policy): record orchestrator blockers durably"
```

### Task 6: Add Human Review State Write Helper

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker.ex`
- Modify: `elixir/lib/symphony_elixir/linear/adapter.ex`
- Create: `elixir/lib/symphony_elixir/runtime_policy/handoff.ex`
- Test: `elixir/test/symphony_elixir/runtime_policy_test.exs`

- [ ] **Step 1: Add handoff test**

```elixir
test "handoff moves linked linear issue to configured human review state" do
  parent = self()

  tracker = fn issue_id, state_name ->
    send(parent, {:state_update, issue_id, state_name})
    :ok
  end

  assert :ok =
           SymphonyElixir.RuntimePolicy.Handoff.move_to_human_review(
             %{linear_issue_id: "issue-1"},
             "Human Review",
             tracker_update: tracker
           )

  assert_received {:state_update, "issue-1", "Human Review"}
end
```

- [ ] **Step 2: Run failing test**

```bash
cd elixir
mix test test/symphony_elixir/runtime_policy_test.exs
```

Expected: missing `RuntimePolicy.Handoff`.

- [ ] **Step 3: Implement Handoff**

```elixir
defmodule SymphonyElixir.RuntimePolicy.Handoff do
  @moduledoc """
  Runtime handoff operations for PR-only workflows.
  """

  alias SymphonyElixir.Tracker

  @spec move_to_human_review(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def move_to_human_review(work, state_name, opts \\ [])
      when is_map(work) and is_binary(state_name) do
    update_fun = Keyword.get(opts, :tracker_update, &Tracker.update_issue_state/2)

    case Map.get(work, :linear_issue_id) || Map.get(work, "linear_issue_id") do
      issue_id when is_binary(issue_id) and issue_id != "" -> update_fun.(issue_id, state_name)
      _ -> :ok
    end
  end
end
```

- [ ] **Step 4: Run tests and commit**

```bash
cd elixir
mix test test/symphony_elixir/runtime_policy_test.exs
git add elixir/lib/symphony_elixir/runtime_policy/handoff.ex elixir/test/symphony_elixir/runtime_policy_test.exs
git commit -m "feat(policy): add human review handoff helper"
```

Expected: tests pass.

### Task 7: Validate Full Runtime Policy Foundation

**Files:**
- Existing files modified in prior tasks.

- [ ] **Step 1: Run targeted suite**

```bash
cd elixir
mix test test/symphony_elixir/work_run_test.exs test/symphony_elixir/runtime_policy_test.exs test/symphony_elixir/orchestrator_status_test.exs
```

Expected: all tests pass.

- [ ] **Step 2: Run repo checks**

```bash
cd elixir
mix format --check-formatted
mix specs.check
```

Expected: both commands exit 0.

- [ ] **Step 3: Run full gate when local Postgres is available**

```bash
cd elixir
make all
```

Expected: full gate exits 0. If Postgres is unavailable, record exact connection failure and run the targeted tests that do not require database access.

