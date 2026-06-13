# Multi-Forge Platform — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Harmony's GitHub-only integration into a pluggable, forge-agnostic platform (GitHub + GitLab, self-hostable) with per-project credentials and a repo/project picker, per `docs/superpowers/specs/2026-06-13-multi-forge-platform-design.md`.

**Architecture:** A `SymphonyElixir.Forge` behaviour mirrors the existing `Tracker` behaviour (`tracker.ex:40`); GitHub is extracted behind it with a configurable base URL; storage/config go forge-agnostic; later phases add per-project secrets, the picker, and a GitLab adapter.

**Tech Stack:** Elixir/Phoenix, Ecto/Postgres, Req (HTTP). Frontend: React 19 + TanStack Query (later phases).

**Working dirs:** backend from `elixir/` (`mise exec -- mix test`); frontend from `elixir/assets/`. TDD throughout; conventional commits ending with the AI footer.

**Plan-level decision (blast-radius control):** Phase 1 renames **storage + domain code** to `forge_*`, but the **web API field names stay `github_*`** — the `Presenter` maps `forge_* → github_*` so the frontend contract and its tests (Phases 1–5 of the frontend) are untouched. Renaming the API/contract surface to `forge_*` is an explicit later follow-up (Milestone 5), not part of this foundation.

---

## Phase 1 — Foundation (detailed)

Baseline before starting: backend `550 tests, 0 failures`. Every task ends green.

### Task 1: `Forge` behaviour + `Forge.Memory` adapter

**Files:**
- Create: `elixir/lib/symphony_elixir/forge.ex`
- Create: `elixir/lib/symphony_elixir/forge/memory.ex`
- Test: `elixir/test/symphony_elixir/forge_test.exs`

- [ ] **Step 1: Write the failing test** — `forge_test.exs`:

```elixir
defmodule SymphonyElixir.ForgeTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Forge

  test "adapter/1 dispatches on the project's forge_type" do
    assert Forge.adapter(%{forge_type: "github"}) == SymphonyElixir.Forge.Github
    assert Forge.adapter(%{forge_type: "gitlab"}) == SymphonyElixir.Forge.Gitlab
    assert Forge.adapter(%{forge_type: nil}) == SymphonyElixir.Forge.Github
  end

  test "Memory adapter records calls and returns seeded results" do
    Forge.Memory.reset()
    Forge.Memory.seed_repositories([%{owner: "o", name: "r", default_branch: "main", url: "u"}])
    assert {:ok, [%{name: "r"}]} = Forge.Memory.list_repositories(%{}, [])
  end
end
```

- [ ] **Step 2: Run it, expect failure** — `mise exec -- mix test test/symphony_elixir/forge_test.exs` → fails (modules undefined).

- [ ] **Step 3: Implement `forge.ex`** (behaviour + dispatch; mirror `tracker.ex`). `Forge.Gitlab` is referenced but not built until Phase 4 — that's fine, dispatch only names the module:

```elixir
defmodule SymphonyElixir.Forge do
  @moduledoc "Adapter boundary for forge (GitHub/GitLab) reads and writes."

  @type creds :: map()
  @type repo_ref :: %{owner: String.t(), repo: String.t(), base_url: String.t() | nil}

  @callback list_repositories(creds, keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback get_repository(creds, String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback list_change_requests(creds, repo_ref, keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback list_pipeline_runs(creds, repo_ref, String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get_pipeline_logs(creds, repo_ref, term()) :: {:ok, binary()} | {:error, term()}
  @callback create_comment(creds, repo_ref, term(), String.t()) :: :ok | {:error, term()}
  @callback create_review(creds, repo_ref, term(), String.t(), keyword()) :: :ok | {:error, term()}

  @spec adapter(map()) :: module()
  def adapter(project) do
    case Map.get(project, :forge_type) || "github" do
      "gitlab" -> SymphonyElixir.Forge.Gitlab
      _ -> SymphonyElixir.Forge.Github
    end
  end
end
```

- [ ] **Step 4: Implement `forge/memory.ex`** — an Agent-backed test double mirroring `tracker/memory.ex` (find it first and copy its registration/reset idiom). Implements `@behaviour SymphonyElixir.Forge`, with `reset/0`, `seed_repositories/1`, `seed_change_requests/1`, `recorded_calls/0`, and each callback returning seeded data + recording the call.

- [ ] **Step 5: Run the test, expect pass.** Then full `mise exec -- mix test` stays green.

- [ ] **Step 6: Commit** — `git commit -m "feat(forge): add Forge behaviour and Memory adapter"`.

### Task 2: `Forge.Github` adapter (configurable base URL)

**Files:**
- Create: `elixir/lib/symphony_elixir/forge/github.ex`
- Modify: `elixir/lib/symphony_elixir/github/client.ex` (add `@api_root` override from opts; add `list_repos`/`get_repo`)
- Test: `elixir/test/symphony_elixir/forge/github_test.exs`

- [ ] **Step 1: Failing test** — assert `Forge.Github` implements the behaviour, normalizes a PR list to the common shape, and honors a `base_url` cred (using the `request_fun` injection the client already supports, e.g. `list_open_pull_requests/3`'s `:request_fun` opt). Example:

```elixir
test "list_change_requests normalizes GitHub PRs and uses base_url" do
  fake = fn opts ->
    assert opts[:url] =~ "https://ghe.example.com/repos/o/r/pulls"
    {:ok, %{status: 200, body: [%{"number" => 7, "head" => %{"sha" => "abc", "ref" => "f"}, "base" => %{"ref" => "main"}, "html_url" => "u"}]}}
  end
  creds = %{token: "t", base_url: "https://ghe.example.com", request_fun: fake}
  ref = %{owner: "o", repo: "r", base_url: "https://ghe.example.com"}
  assert {:ok, [%{number: 7, head_sha: "abc"}]} = SymphonyElixir.Forge.Github.list_change_requests(creds, ref, [])
end
```

- [ ] **Step 2: Run, expect fail.**

- [ ] **Step 3: Make `@api_root` overridable in `github/client.ex`.** Replace the hardcoded `@api_root` usage with `api_root(opts)` reading `opts[:base_url] || @default_api_root` (default `"https://api.github.com"`). Thread `base_url` through every public function's `opts`. Add `list_repos(opts)` (`GET /user/repos` or `/orgs/{org}/repos` when `opts[:org]`) and `get_repo(owner, repo, opts)` (`GET /repos/{owner}/{repo}` → default_branch). Keep the existing positional API and `request_fun`/`token` opts intact — existing `github_client_test.exs` must stay green.

- [ ] **Step 4: Implement `forge/github.ex`** — `@behaviour SymphonyElixir.Forge`, delegating to `Github.Client`, translating `creds` (`%{token, base_url, request_fun, org}`) into client opts and normalizing results to the common shapes (`repo: %{owner, name, default_branch, url}`, `change_request: %{number, head_sha, head_ref, base_ref, url}`, `pipeline_run: %{id, name, status, conclusion, head_sha}`).

- [ ] **Step 5: Run forge + client tests, expect pass.** Full suite green.

- [ ] **Step 6: Commit** — `git commit -m "feat(forge): GitHub adapter with configurable base URL and repo listing"`.

### Task 3: Storage migration — add `forge_*` columns + backfill

**Files:**
- Create: `elixir/priv/repo/migrations/<ts>_add_forge_columns.exs` (timestamp per the convention, e.g. `20260613120000_...`)
- Test: covered by Task 4's schema tests + a backfill assertion.

- [ ] **Step 1: Write the migration** — additive, reversible:

```elixir
defmodule SymphonyElixir.Repo.Migrations.AddForgeColumns do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :forge_type, :string, default: "github", null: false
      add :forge_owner, :string
      add :forge_repo, :string
      add :forge_base_branch, :string
      add :forge_base_url, :string
    end
    alter table(:work_runs) do
      add :forge_owner, :string
      add :forge_repo, :string
      add :forge_pr_number, :integer
      add :forge_head_sha, :string
      add :forge_head_ref, :string
      add :forge_base_ref, :string
    end
    alter table(:pull_request_links) do
      add :forge_owner, :string
      add :forge_repo, :string
      add :forge_pr_number, :integer
      add :forge_head_sha, :string
      add :forge_head_ref, :string
      add :forge_base_ref, :string
    end

    # Backfill: every existing row is GitHub.
    execute(
      """
      UPDATE projects SET forge_owner = github_owner, forge_repo = github_repo,
        forge_base_branch = github_base_branch WHERE forge_owner IS NULL;
      """,
      "SELECT 1"
    )
    execute(
      """
      UPDATE work_runs SET forge_owner = github_owner, forge_repo = github_repo,
        forge_pr_number = github_pr_number, forge_head_sha = github_head_sha,
        forge_head_ref = github_head_ref, forge_base_ref = github_base_ref;
      """,
      "SELECT 1"
    )
    execute(
      """
      UPDATE pull_request_links SET forge_owner = github_owner, forge_repo = github_repo,
        forge_pr_number = github_pr_number, forge_head_sha = github_head_sha,
        forge_head_ref = github_head_ref, forge_base_ref = github_base_ref;
      """,
      "SELECT 1"
    )
  end
end
```

- [ ] **Step 2: Migrate dev + test** — `mise exec -- mix ecto.migrate && MIX_ENV=test mise exec -- mix ecto.migrate`. Expected: both succeed.

- [ ] **Step 3: Commit** — `git commit -m "feat(storage): add forge_* columns and backfill from github_*"`.

### Task 4: Schemas + changesets dual-read `forge_*`

**Files:**
- Modify: `elixir/lib/symphony_elixir/storage/project.ex`, `storage/work_run.ex`, `storage/pull_request_link.ex`
- Test: `elixir/test/symphony_elixir/storage_test.exs` (extend)

- [ ] **Step 1: Failing test** — insert a project with `forge_type`/`forge_owner`/`forge_repo`/`forge_base_branch`; assert it persists and reads back; assert `forge_type` defaults to `"github"`.

- [ ] **Step 2: Run, expect fail** (fields not cast yet).

- [ ] **Step 3: Add the `forge_*` fields to each schema + `cast`** alongside the existing `github_*` fields (keep both during transition). On `Project`, switch `validate_required` from `github_*` to `forge_owner/forge_repo/forge_base_branch/forge_type`. On `WorkRun`/`PullRequestLink`, add the `forge_*` to `cast`; keep `github_*` required for now (Sync still writes both until Task 5). Add the `forge_*` schema fields:

```elixir
# storage/project.ex — add to schema:
field(:forge_type, :string, default: "github")
field(:forge_owner, :string)
field(:forge_repo, :string)
field(:forge_base_branch, :string)
field(:forge_base_url, :string)
```

- [ ] **Step 4: Run, expect pass.** Full suite green.

- [ ] **Step 5: Commit** — `git commit -m "feat(storage): cast and read forge_* fields"`.

### Task 5: Config schema + Sync → `forge`

**Files:**
- Modify: `elixir/lib/symphony_elixir/project_config/schema.ex`, `project_config/sync.ex`
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs` (or the config schema test — find the existing one)

- [ ] **Step 1: Failing test** — `Schema.parse/1` accepts a `forge:` section `{type, owner, repo, base_branch, base_url, protected_branches}`, AND still accepts a legacy `github:` section (mapped to `forge_type: "github"`). `Sync.attrs/1` produces `forge_owner`/`forge_repo`/`forge_base_branch`/`forge_type` (and keeps writing `github_*` for the transition).

- [ ] **Step 2: Run, expect fail.**

- [ ] **Step 3: Implement** — rename the `Github` struct to `Forge` (`type: "github"`, `owner`, `repo`, `base_branch`, `base_url`, `protected_branches`); `parse_forge/1` reads `forge:` else falls back to the legacy `github:` map (defaulting `type` to `"github"`). `Sync.attrs/1` maps to `forge_*` AND `github_*` (dual-write during transition):

```elixir
defp attrs(%Schema{} = config) do
  %{
    slug: config.slug,
    linear_project_slug: config.linear.project_slug,
    linear_team_key: config.linear.team_key,
    linear_human_review_state: config.linear.human_review_state,
    forge_type: config.forge.type,
    forge_owner: config.forge.owner,
    forge_repo: config.forge.repo,
    forge_base_branch: config.forge.base_branch,
    forge_base_url: config.forge.base_url,
    github_owner: config.forge.owner,
    github_repo: config.forge.repo,
    github_base_branch: config.forge.base_branch,
    config_version: config.review.template_version,
    config: config.raw
  }
end
```

- [ ] **Step 4: Run, expect pass.** Full suite green.

- [ ] **Step 5: Commit** — `git commit -m "feat(config): forge config section with legacy github alias"`.

### Task 6: Repoint work sources + handoffs through `Forge.adapter`

**Files:**
- Modify: `elixir/lib/symphony_elixir/work_sources/github_pr_source.ex`, `github_failed_ci_source.ex`, `github_review_request_source.ex`
- Modify: `elixir/lib/symphony_elixir/workflows/review_handoff.ex`, `ci_fix_handoff.ex`, and any other direct `Github.Client` caller (grep `Github.Client` to enumerate)
- Modify: the orchestrator CI-fix dispatch path that reads `github_owner/repo`

- [ ] **Step 1:** `grep -rn "Github.Client\." elixir/lib` to enumerate every call site. For each, replace the direct call with `Forge.adapter(project).<op>(creds_for(project), repo_ref(project), …)`, where `creds_for/1` builds `%{token: <env for now>, base_url: project.forge_base_url, request_fun: …}` and `repo_ref/1` reads `forge_owner`/`forge_repo` (falling back to `github_*`). Read `forge_owner`/`forge_repo` from the project/work_run instead of `github_owner`/`github_repo` at these call sites.

- [ ] **Step 2:** Run the full backend suite — `mise exec -- mix test`. The work-source/handoff/orchestrator tests are the regression net; they must stay green. Where a test stubs `Github.Client` directly, repoint it to seed `Forge.Memory` (the project's `forge_type` is `"github"`, so production still hits `Forge.Github`; tests can inject the Memory adapter via the project or a config override — mirror how tracker tests use `Tracker.Memory`).

- [ ] **Step 3: Commit** — `git commit -m "refactor(forge): route work sources and handoffs through the Forge behaviour"`.

### Task 7: Presenter maps `forge_* → github_*`; drop legacy columns

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex` (durable + run payloads read `forge_*`, emit existing `github_*` API keys)
- Modify: `storage/work_run.ex`, `storage/pull_request_link.ex` (stop requiring `github_*`; require `forge_*`)
- Modify: `project_config/sync.ex` (drop the `github_*` dual-write)
- Create: `elixir/priv/repo/migrations/<ts>_drop_github_columns.exs`

- [ ] **Step 1:** Update `Presenter` payload builders to read `work_run.forge_owner`/`forge_pr_number`/etc. but keep emitting the JSON keys `github_owner`/`github_pr_number`/… (so `state_payload`, `run_detail`, `project_summary`, `work_run_list` contracts and the frontend types are unchanged). Run the existing Elixir contract tests + the frontend `npm run test -- --run` — both must stay green (proving the API surface is stable).

- [ ] **Step 2:** Flip `WorkRun`/`PullRequestLink` changesets to require `forge_*` (not `github_*`); drop the `github_*` dual-write in `Sync.attrs`.

- [ ] **Step 3:** Write the drop migration (`alter table … remove :github_owner, …` for all three tables; `change` with explicit `up`/`down` so it's reversible). Migrate dev + test.

- [ ] **Step 4:** Full backend suite + frontend suite green. **Phase 1 done:** behaviorally identical, routed through `Forge`, storage forge-agnostic, GitHub Enterprise base URL configurable, API/frontend untouched.

- [ ] **Step 5: Commit** — `git commit -m "refactor(storage): drop github_* columns; presenter maps forge_* to stable API keys"`.

---

## Phase 2 — Per-project credentials (milestone)

**Goal:** each project carries its own encrypted forge token + tracker key; clients resolve credentials per-call from the project, global env as fallback.

**Shape:** add encrypted `forge_secret` / `tracker_secret` columns to `projects` (encryption via `Cloak`-style vault or `:crypto` with an app key from env). `creds_for(project)` (introduced in Task 6) resolves the project secret, falling back to env. A write-only secrets API (`PUT /api/v1/projects/:id/secrets`) accepts tokens; reads return only `forge_secret_set: bool`, never the value. The Configuration form gains password fields showing `set | unset`. Key material is an operational secret (env/secret manager), documented.

**Risks:** encryption-key management is the crux; if deferred, fall back to the per-project `$VAR`-reference model (store an env-var name, not the value). **Testing:** encrypt/decrypt round-trip; assert no endpoint ever returns a secret value; `creds_for` precedence (project secret > env). Independently shippable: with no secret set, behavior is identical to Phase 1 (env fallback).

## Phase 3 — Project picker (milestone)

**Goal:** choose a forge repo and a tracker project from lists in the Configuration tab instead of typing slugs.

**Shape:** `Forge.list_repositories/2` (already added for GitHub in Task 2; GitLab in Phase 4) + `Tracker.list_projects/1` (new Linear GraphQL query: teams → projects with slugs; extend `linear/client.ex` + `Tracker` behaviour + `Tracker.Memory`). New read endpoints `GET /api/v1/forge/repositories` and `GET /api/v1/tracker/projects` using the **project's** credentials (depends on Phase 2). Frontend: shadcn combobox pickers in `ProjectConfigForm`, replacing the free-text repo/slug fields, with access validation. Shared contract fixtures per the established pattern.

**Risks:** pagination of large repo/project lists; credential errors surfaced cleanly in the picker. **Testing:** client list-op tests; contract fixtures; frontend component + an e2e picker flow. Independently shippable: pickers are additive to the existing form, which keeps working for manual entry.

## Phase 4 — GitLab adapter + work sources (milestone)

**Goal:** full GitLab support, including self-hosted, on the Phase 1 abstraction.

**Shape:** `Forge.Gitlab` (REST, configurable `instance_url`): `GET /projects?membership=true`, MRs (`/merge_requests`), pipelines (`/pipelines` + jobs) for the CI equivalent, notes for comments, MR-level review. Map GitLab's namespace/group + MR/pipeline onto the common normalized shapes so work sources stay forge-neutral. Add `GitlabMrSource` + `GitlabPipelineSource` under the `WorkSource` behaviour, selected by `project.forge_type`. Self-hosted GitLab = a configured `forge_base_url`/`instance_url`.

**Risks:** REST divergence (pipelines vs Actions, namespace vs owner, MR vs PR) — absorbed by the normalized `Forge` shapes; iid-vs-id semantics in GitLab APIs. **Testing:** adapter tests against recorded REST fixtures; the GitLab work sources mirror the GitHub work-source tests; an end-to-end memory-adapter test of a `forge_type: "gitlab"` project flowing through dispatch.

## Milestone 5 (optional) — Forge-agnostic API surface

If desired after Phase 4: rename the web API field names `github_* → forge_*` and update the frontend contract/types, removing the Presenter compatibility mapping from Task 7. Deferred deliberately so the foundation never blocks on re-running the entire frontend.

---

## Self-review notes

- **Spec coverage:** Forge behaviour (T1), GitHub adapter + base URL (T2), storage refactor (T3–T4, T7), config (T5), repoint (T6), per-project creds (Ph2), picker (Ph3), GitLab (Ph4) — all spec sections map to a task/milestone.
- **API stability:** the Presenter mapping (T7) keeps the frontend contract green throughout Phase 1; the API rename is the explicit, optional Milestone 5.
- **Naming consistency:** `forge_type`, `forge_owner`, `forge_repo`, `forge_base_branch`, `forge_base_url`, `forge_pr_number`, `forge_head_sha`, `forge_head_ref`, `forge_base_ref` used uniformly across schema, config, and migration.
