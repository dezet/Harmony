# GitLab Adapter (Multi-Forge Phase 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add full GitLab support (gitlab.com + self-hosted) at feature parity with GitHub — MR observation, pipeline CI repair, and `@hreview` comment-triggered review — on the merged Phase 1 `Forge` abstraction.

**Architecture:** Mirror the proven GitHub modules. A new `Gitlab.Client` (REST v4, configurable `instance_url`) backs rich structs and a `Forge.Gitlab` adapter implementing every `Forge` callback. Three GitLab work sources mirror their GitHub counterparts. The orchestrator gains a `forge_type` dispatch wrapper that picks GitLab sources for `forge_type: "gitlab"` projects. Handoffs and credential resolution become forge-neutral. No new DB migrations (Phase 1 `forge_*` columns suffice); credentials use a global `GITLAB_TOKEN` env (Phase 2 per-project secrets are out of scope).

**Tech Stack:** Elixir/OTP, `Req` (HTTP), ExUnit. Backend only — the web API field names stay `github_*` via the Phase 1 Presenter mapping, so the frontend is untouched.

**Working dir:** `elixir/`. Run tests with `mise exec -- mix test` (set `MISE_TRUSTED_CONFIG_PATHS=$PWD/mise.toml` if mise prompts). TDD throughout; conventional commits ending with the AI footer.

**Spec:** `docs/superpowers/specs/2026-06-13-gitlab-adapter-design.md`.

**Reference files to mirror (read before starting):**
- `lib/symphony_elixir/github/client.ex` — client shape, `request_fun`/`token`/`base_url` opts, `expect_status`.
- `lib/symphony_elixir/github/{pull_request,workflow_run,comment}.ex` — struct + `from_api/1` pattern.
- `lib/symphony_elixir/forge/{github,memory,project_creds}.ex` — adapter + creds helpers.
- `lib/symphony_elixir/work_sources/github_{pr,failed_ci,review_request}_source.ex` — work-source pattern (injectable fetchers via `opts`).
- `lib/symphony_elixir/workflows/{ci_fix_handoff,review_handoff}.ex` — handoff calls.
- `lib/symphony_elixir/orchestrator.ex:480-494` — work-source fetcher injection.

---

## File Structure

**Create:**
- `lib/symphony_elixir/gitlab/client.ex` — GitLab REST v4 client (`Gitlab.Client`).
- `lib/symphony_elixir/gitlab/merge_request.ex` — `Gitlab.MergeRequest` struct + `from_api/1`.
- `lib/symphony_elixir/gitlab/pipeline.ex` — `Gitlab.Pipeline` struct + `from_api/1`.
- `lib/symphony_elixir/gitlab/job.ex` — `Gitlab.Job` struct + `from_api/1`.
- `lib/symphony_elixir/gitlab/note.ex` — `Gitlab.Note` struct + `from_api/1`.
- `lib/symphony_elixir/forge/gitlab.ex` — `Forge.Gitlab` adapter.
- `lib/symphony_elixir/work_sources/gitlab_mr_source.ex` — MR observation.
- `lib/symphony_elixir/work_sources/gitlab_pipeline_source.ex` — failed-pipeline CI repair.
- `lib/symphony_elixir/work_sources/gitlab_review_request_source.ex` — `@hreview` trigger.
- Test files mirroring each under `test/symphony_elixir/`.

**Modify:**
- `lib/symphony_elixir/forge.ex` — add `list_change_request_comments/3` callback.
- `lib/symphony_elixir/forge/github.ex` — implement the new callback.
- `lib/symphony_elixir/forge/memory.ex` — implement the new callback + seed helper.
- `lib/symphony_elixir/forge/project_creds.ex` — forge-aware `creds/2`; add `gitlab_client_opts/2`.
- `lib/symphony_elixir/work_sources/github_review_request_source.ex` — fetch comments via the adapter.
- `lib/symphony_elixir/workflows/{ci_fix_handoff,review_handoff}.ex` — dispatch via `Forge.adapter/1`.
- `lib/symphony_elixir/orchestrator.ex` — `forge_type` dispatch wrapper.

---

## Task 1: `list_change_request_comments` behaviour callback (GitHub side)

Adds the missing behaviour callback and implements it for GitHub + Memory, retiring the Phase 1 follow-up. Parity-neutral: GitHub behavior is unchanged.

**Files:**
- Modify: `lib/symphony_elixir/forge.ex`
- Modify: `lib/symphony_elixir/forge/github.ex`
- Modify: `lib/symphony_elixir/forge/memory.ex`
- Test: `test/symphony_elixir/forge/github_test.exs`, `test/symphony_elixir/forge_test.exs`

- [ ] **Step 1: Write the failing test** — append to `test/symphony_elixir/forge/github_test.exs`:

```elixir
test "list_change_request_comments normalizes GitHub issue comments and honors base_url" do
  fake = fn opts ->
    assert opts[:method] == :get
    assert opts[:url] =~ "https://ghe.example.com/repos/o/r/issues/7/comments"
    {:ok, %{status: 200, body: [%{"id" => 11, "body" => "@hreview please", "user" => %{"login" => "octo"}}]}}
  end

  creds = %{token: "t", base_url: "https://ghe.example.com", request_fun: fake}
  ref = %{owner: "o", repo: "r", base_url: "https://ghe.example.com"}

  assert {:ok, [%SymphonyElixir.Github.Comment{id: 11, body: "@hreview please", author: "octo"}]} =
           SymphonyElixir.Forge.Github.list_change_request_comments(creds, ref, 7)
end
```

- [ ] **Step 2: Run it, expect failure**

Run: `mise exec -- mix test test/symphony_elixir/forge/github_test.exs`
Expected: FAIL — `function SymphonyElixir.Forge.Github.list_change_request_comments/3 is undefined`.

- [ ] **Step 3: Add the callback to the behaviour** — in `lib/symphony_elixir/forge.ex`, after the `create_review` callback:

```elixir
  @callback list_change_request_comments(creds, repo_ref, term()) ::
              {:ok, [map()]} | {:error, term()}
```

- [ ] **Step 4: Implement it for GitHub** — in `lib/symphony_elixir/forge/github.ex`, add after `create_review/5`:

```elixir
  @impl true
  def list_change_request_comments(creds, ref, issue_number) do
    Client.list_issue_comments(ref.owner, ref.repo, issue_number, client_opts(creds))
  end
```

- [ ] **Step 5: Implement it for Memory** — in `lib/symphony_elixir/forge/memory.ex`: add `comments: []` to `initial_state/0`, a `seed_comments/1` helper mirroring `seed_change_requests/1`, and the callback:

```elixir
  @doc "Seed the comments returned by `list_change_request_comments/3`."
  @spec seed_comments([map()]) :: :ok
  def seed_comments(comments) when is_list(comments) do
    ensure_started()
    Agent.update(@agent, &Map.put(&1, :comments, comments))
  end

  @impl SymphonyElixir.Forge
  def list_change_request_comments(creds, repo_ref, change_id) do
    record_call(:list_change_request_comments, [creds, repo_ref, change_id])
    {:ok, Agent.get(@agent, & &1.comments)}
  end
```

- [ ] **Step 6: Run tests, expect pass**

Run: `mise exec -- mix test test/symphony_elixir/forge/github_test.exs test/symphony_elixir/forge_test.exs`
Expected: PASS.

- [ ] **Step 7: Repoint the GitHub review source's comment fetch** — in `lib/symphony_elixir/work_sources/github_review_request_source.ex`, replace the `list_issue_comments` default (lines 26-32) so it goes through the adapter, keeping the injectable 4-arg shape for tests:

```elixir
    creds = ProjectCreds.creds(project, opts)

    list_issue_comments =
      Keyword.get(opts, :list_issue_comments, fn _owner, _repo, issue_number, _call_opts ->
        SymphonyElixir.Forge.adapter(project).list_change_request_comments(creds, ref, issue_number)
      end)
```

Add `alias SymphonyElixir.Forge` to the existing `alias` line if not already reachable (it is via fully-qualified `SymphonyElixir.Forge.adapter/1`; the explicit alias is optional).

- [ ] **Step 8: Run the review-source suite, expect pass**

Run: `mise exec -- mix test test/symphony_elixir/github_review_request_source_test.exs`
Expected: PASS (tests inject `:list_issue_comments`, so the default change is transparent).

- [ ] **Step 9: Full suite green, then commit**

```bash
mise exec -- mix test
git add lib/symphony_elixir/forge.ex lib/symphony_elixir/forge/github.ex lib/symphony_elixir/forge/memory.ex lib/symphony_elixir/work_sources/github_review_request_source.ex test/symphony_elixir/forge/github_test.exs
git commit -m "feat(forge): add list_change_request_comments callback; route review-source comments through the adapter

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Forge-neutral credentials + handoffs

`ProjectCreds.creds/2` hardcodes `GITHUB_TOKEN`, and the handoffs call `Forge.Github.*` directly. Make both forge-aware so a `gitlab` project's handoff posts to GitLab with a GitLab token. GitHub behavior is unchanged.

**Files:**
- Modify: `lib/symphony_elixir/forge/project_creds.ex`
- Modify: `lib/symphony_elixir/workflows/ci_fix_handoff.ex`
- Modify: `lib/symphony_elixir/workflows/review_handoff.ex`
- Test: `test/symphony_elixir/project_creds_test.exs` (create if absent), existing handoff tests

- [ ] **Step 1: Write the failing test** — create/append `test/symphony_elixir/project_creds_test.exs`:

```elixir
defmodule SymphonyElixir.Forge.ProjectCredsTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Forge.ProjectCreds

  test "creds/2 selects the GitLab token for gitlab projects" do
    System.put_env("GITLAB_TOKEN", "gl-secret")
    on_exit(fn -> System.delete_env("GITLAB_TOKEN") end)

    creds = ProjectCreds.creds(%{forge_type: "gitlab", forge_base_url: "https://gl.example.com"})
    assert creds.token == "gl-secret"
    assert creds.base_url == "https://gl.example.com"
  end

  test "gitlab_client_opts/2 carries base_url and request_fun" do
    fun = fn _ -> {:ok, %{status: 200, body: []}} end
    opts = ProjectCreds.gitlab_client_opts(%{forge_base_url: "https://gl.example.com"}, request_fun: fun)
    assert opts[:base_url] == "https://gl.example.com"
    assert opts[:request_fun] == fun
  end
end
```

- [ ] **Step 2: Run it, expect failure**

Run: `mise exec -- mix test test/symphony_elixir/project_creds_test.exs`
Expected: FAIL — `creds.token` is the GitHub token / `gitlab_client_opts/2` undefined.

- [ ] **Step 3: Make `creds/2` forge-aware and add `gitlab_client_opts/2`** — in `lib/symphony_elixir/forge/project_creds.ex`, replace the `creds/2` body and add the helper:

```elixir
  @spec creds(map(), keyword()) :: map()
  def creds(project_or_run, extra \\ []) do
    %{
      token: forge_token(project_or_run),
      base_url: map_get(project_or_run, :forge_base_url),
      request_fun: extra[:request_fun]
    }
  end

  @spec gitlab_client_opts(map(), keyword()) :: keyword()
  def gitlab_client_opts(project_or_run, extra \\ []) do
    []
    |> put_if(System.get_env("GITLAB_TOKEN"), :token)
    |> put_if(map_get(project_or_run, :forge_base_url), :base_url)
    |> put_if(extra[:request_fun], :request_fun)
  end

  defp forge_token(project_or_run) do
    case map_get(project_or_run, :forge_type) do
      "gitlab" -> System.get_env("GITLAB_TOKEN")
      _ -> System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
    end
  end
```

- [ ] **Step 4: Run the creds test, expect pass**

Run: `mise exec -- mix test test/symphony_elixir/project_creds_test.exs`
Expected: PASS.

- [ ] **Step 5: Route the CI-fix handoff through the adapter** — in `lib/symphony_elixir/workflows/ci_fix_handoff.ex`, replace the direct `Forge.Github.create_comment(creds, ref, issue_number, comment_body)` call (around line 22) with:

```elixir
        SymphonyElixir.Forge.adapter(run).create_comment(creds, ref, issue_number, comment_body)
```

- [ ] **Step 6: Route the review handoff through the adapter** — in `lib/symphony_elixir/workflows/review_handoff.ex`, replace the default `create_review` fun body (lines 16-18) with:

```elixir
      Keyword.get(opts, :create_review, fn _owner, _repo, pr_number, review_body, call_opts ->
        ref = %{owner: run.forge_owner, repo: run.forge_repo, base_url: creds.base_url}
        SymphonyElixir.Forge.adapter(run).create_review(creds, ref, pr_number, review_body, call_opts)
      end)
```

- [ ] **Step 7: Run the handoff suites, expect pass**

Run: `mise exec -- mix test test/symphony_elixir/ci_fix_handoff_test.exs test/symphony_elixir/review_handoff_test.exs`
Expected: PASS (existing GitHub runs have `forge_type` nil/`"github"` → `Forge.adapter` returns `Forge.Github`, identical behavior).

- [ ] **Step 8: Full suite green, then commit**

```bash
mise exec -- mix test
git add lib/symphony_elixir/forge/project_creds.ex lib/symphony_elixir/workflows/ci_fix_handoff.ex lib/symphony_elixir/workflows/review_handoff.ex test/symphony_elixir/project_creds_test.exs
git commit -m "feat(forge): forge-aware credentials and adapter-dispatched handoffs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: GitLab structs

Four normalized structs mirroring the GitHub structs, carrying the rich fields the work sources need.

**Files:**
- Create: `lib/symphony_elixir/gitlab/merge_request.ex`, `pipeline.ex`, `job.ex`, `note.ex`
- Test: `test/symphony_elixir/gitlab/structs_test.exs`

- [ ] **Step 1: Write the failing test** — `test/symphony_elixir/gitlab/structs_test.exs`:

```elixir
defmodule SymphonyElixir.Gitlab.StructsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Gitlab.{MergeRequest, Pipeline, Job, Note}

  test "MergeRequest.from_api maps iid, branches, sha, fork project ids" do
    raw = %{
      "iid" => 5, "title" => "Fix", "description" => "ABC-1", "web_url" => "u",
      "sha" => "deadbeef", "source_branch" => "feature", "target_branch" => "main",
      "source_project_id" => 42, "target_project_id" => 7, "project_id" => 7
    }

    mr = MergeRequest.from_api(raw)
    assert mr.number == 5
    assert mr.head_sha == "deadbeef"
    assert mr.head_ref == "feature"
    assert mr.base_ref == "main"
    assert mr.body == "ABC-1"
    assert mr.head_repo_full_name == "42"
    assert mr.base_repo_full_name == "7"
    assert mr.project_id == 7
  end

  test "Pipeline.from_api maps id/status/sha" do
    p = Pipeline.from_api(%{"id" => 99, "status" => "failed", "ref" => "feature", "sha" => "abc", "web_url" => "u"})
    assert p.id == 99 and p.status == "failed" and p.sha == "abc"
  end

  test "Job.from_api maps id/name/status" do
    j = Job.from_api(%{"id" => 3, "name" => "test", "status" => "failed"})
    assert j.id == 3 and j.name == "test" and j.status == "failed"
  end

  test "Note.from_api maps id/body/author" do
    n = Note.from_api(%{"id" => 8, "body" => "@hreview", "author" => %{"username" => "dev"}})
    assert n.id == 8 and n.body == "@hreview" and n.author == "dev"
  end
end
```

- [ ] **Step 2: Run it, expect failure**

Run: `mise exec -- mix test test/symphony_elixir/gitlab/structs_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 3: Implement `merge_request.ex`**

```elixir
defmodule SymphonyElixir.Gitlab.MergeRequest do
  @moduledoc "Normalized GitLab merge request data used by Harmony work sources."

  defstruct [
    :number, :title, :body, :url, :head_sha, :head_ref, :base_ref,
    :head_repo_full_name, :base_repo_full_name, :project_id
  ]

  @type t :: %__MODULE__{}

  @spec from_api(map()) :: t()
  def from_api(raw) when is_map(raw) do
    %__MODULE__{
      number: raw["iid"],
      title: raw["title"],
      body: raw["description"],
      url: raw["web_url"],
      head_sha: raw["sha"] || get_in(raw, ["diff_refs", "head_sha"]),
      head_ref: raw["source_branch"],
      base_ref: raw["target_branch"],
      head_repo_full_name: to_string_or_nil(raw["source_project_id"]),
      base_repo_full_name: to_string_or_nil(raw["target_project_id"]),
      project_id: raw["project_id"] || raw["target_project_id"]
    }
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)
end
```

- [ ] **Step 4: Implement `pipeline.ex`**

```elixir
defmodule SymphonyElixir.Gitlab.Pipeline do
  @moduledoc "Normalized GitLab pipeline data."

  defstruct [:id, :status, :ref, :sha, :url]

  @type t :: %__MODULE__{}

  @spec from_api(map()) :: t()
  def from_api(raw) when is_map(raw) do
    %__MODULE__{
      id: raw["id"],
      status: raw["status"],
      ref: raw["ref"],
      sha: raw["sha"],
      url: raw["web_url"]
    }
  end
end
```

- [ ] **Step 5: Implement `job.ex`**

```elixir
defmodule SymphonyElixir.Gitlab.Job do
  @moduledoc "Normalized GitLab pipeline job data."

  defstruct [:id, :name, :status]

  @type t :: %__MODULE__{}

  @spec from_api(map()) :: t()
  def from_api(raw) when is_map(raw) do
    %__MODULE__{id: raw["id"], name: raw["name"], status: raw["status"]}
  end
end
```

- [ ] **Step 6: Implement `note.ex`**

```elixir
defmodule SymphonyElixir.Gitlab.Note do
  @moduledoc "Normalized GitLab MR note (comment) data."

  defstruct [:id, :body, :author]

  @type t :: %__MODULE__{}

  @spec from_api(map()) :: t()
  def from_api(raw) when is_map(raw) do
    %__MODULE__{id: raw["id"], body: raw["body"], author: get_in(raw, ["author", "username"])}
  end
end
```

- [ ] **Step 7: Run the struct test, expect pass; commit**

```bash
mise exec -- mix test test/symphony_elixir/gitlab/structs_test.exs
git add lib/symphony_elixir/gitlab/ test/symphony_elixir/gitlab/structs_test.exs
git commit -m "feat(gitlab): add MergeRequest/Pipeline/Job/Note structs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `Gitlab.Client` (REST v4)

Mirrors `Github.Client`: `request_fun`/`token`/`base_url` opts, `PRIVATE-TOKEN` auth, `GITLAB_TOKEN` env default, URL-encoded project path, `expect_status` error shape.

**Files:**
- Create: `lib/symphony_elixir/gitlab/client.ex`
- Test: `test/symphony_elixir/gitlab/client_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
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
```

- [ ] **Step 2: Run it, expect failure**

Run: `mise exec -- mix test test/symphony_elixir/gitlab/client_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the client**

```elixir
defmodule SymphonyElixir.Gitlab.Client do
  @moduledoc "Minimal GitLab REST v4 client for Harmony MR/pipeline polling."

  alias SymphonyElixir.Gitlab.{MergeRequest, Pipeline, Job, Note}

  @default_host "https://gitlab.com"

  defp api_root(opts), do: "#{Keyword.get(opts, :base_url) || @default_host}/api/v4"
  defp project_path(owner, repo), do: URI.encode_www_form("#{owner}/#{repo}")

  @spec list_projects(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_projects(opts \\ []) do
    get(opts, "/projects", params: [membership: true, per_page: 100], parse: & &1)
  end

  @spec get_project(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_project(owner, repo, opts \\ []) do
    get(opts, "/projects/#{project_path(owner, repo)}", parse: & &1)
  end

  @spec list_open_merge_requests(String.t(), String.t(), keyword()) :: {:ok, [MergeRequest.t()]} | {:error, term()}
  def list_open_merge_requests(owner, repo, opts \\ []) do
    get(opts, "/projects/#{project_path(owner, repo)}/merge_requests",
      params: [state: "opened", per_page: 100],
      parse: &Enum.map(&1, fn raw -> MergeRequest.from_api(raw) end)
    )
  end

  @spec list_pipelines(String.t(), String.t(), keyword()) :: {:ok, [Pipeline.t()]} | {:error, term()}
  def list_pipelines(owner, repo, opts \\ []) do
    params = [per_page: 100] ++ if(opts[:sha], do: [sha: opts[:sha]], else: [])

    get(opts, "/projects/#{project_path(owner, repo)}/pipelines",
      params: params,
      parse: &Enum.map(&1, fn raw -> Pipeline.from_api(raw) end)
    )
  end

  @spec list_pipeline_jobs(String.t(), String.t(), pos_integer(), keyword()) :: {:ok, [Job.t()]} | {:error, term()}
  def list_pipeline_jobs(owner, repo, pipeline_id, opts \\ []) do
    get(opts, "/projects/#{project_path(owner, repo)}/pipelines/#{pipeline_id}/jobs",
      params: [per_page: 100],
      parse: &Enum.map(&1, fn raw -> Job.from_api(raw) end)
    )
  end

  @spec get_job_trace(String.t(), String.t(), pos_integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_job_trace(owner, repo, job_id, opts \\ []) do
    get(opts, "/projects/#{project_path(owner, repo)}/jobs/#{job_id}/trace", parse: & &1)
  end

  @spec list_merge_request_notes(String.t(), String.t(), pos_integer(), keyword()) :: {:ok, [Note.t()]} | {:error, term()}
  def list_merge_request_notes(owner, repo, mr_iid, opts \\ []) do
    get(opts, "/projects/#{project_path(owner, repo)}/merge_requests/#{mr_iid}/notes",
      params: [per_page: 100],
      parse: &Enum.map(&1, fn raw -> Note.from_api(raw) end)
    )
  end

  @spec create_merge_request_note(String.t(), String.t(), pos_integer(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_merge_request_note(owner, repo, mr_iid, body, opts \\ []) when is_binary(body) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    url = "#{api_root(opts)}/projects/#{project_path(owner, repo)}/merge_requests/#{mr_iid}/notes"

    case request_fun.(method: :post, url: url, json: %{body: body}, headers: headers(token(opts))) do
      {:ok, response} -> expect_status(response, [200, 201])
      {:error, reason} -> {:error, reason}
    end
  end

  # --- shared GET ---

  defp get(opts, path, call_opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    parse = Keyword.fetch!(call_opts, :parse)
    req = [method: :get, url: "#{api_root(opts)}#{path}", headers: headers(token(opts))]
    req = if call_opts[:params], do: Keyword.put(req, :params, call_opts[:params]), else: req

    with {:ok, response} <- request_fun.(req),
         :ok <- expect_status(response, 200) do
      {:ok, parse.(response.body)}
    end
  end

  defp token(opts), do: Keyword.get(opts, :token) || System.get_env("GITLAB_TOKEN")

  defp headers(token) when is_binary(token) and token != "", do: [{"private-token", token}, {"accept", "application/json"}]
  defp headers(_token), do: [{"accept", "application/json"}]

  defp expect_status(%{status: status}, expected) when is_list(expected) do
    if status in expected, do: :ok, else: {:error, {:gitlab_status, status}}
  end

  defp expect_status(%{status: status}, expected) when status == expected, do: :ok
  defp expect_status(%{status: status, body: body}, _expected), do: {:error, {:gitlab_status, status, body}}
end
```

- [ ] **Step 4: Run the client test, expect pass; full suite green; commit**

```bash
mise exec -- mix test test/symphony_elixir/gitlab/client_test.exs && mise exec -- mix test
git add lib/symphony_elixir/gitlab/client.ex test/symphony_elixir/gitlab/client_test.exs
git commit -m "feat(gitlab): REST v4 client (MRs, pipelines, jobs, traces, notes)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `Forge.Gitlab` adapter

Implements every `Forge` callback by delegating to `Gitlab.Client` and normalizing to the common shapes. `Forge.adapter/1` already dispatches `"gitlab"` here.

**Files:**
- Create: `lib/symphony_elixir/forge/gitlab.ex`
- Test: `test/symphony_elixir/forge/gitlab_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
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
```

- [ ] **Step 2: Run it, expect failure**

Run: `mise exec -- mix test test/symphony_elixir/forge/gitlab_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the adapter**

```elixir
defmodule SymphonyElixir.Forge.Gitlab do
  @moduledoc """
  Forge adapter for GitLab (gitlab.com and self-hosted).

  Accepts creds as a map with optional keys: `:token`, `:base_url`
  (the GitLab `instance_url`), `:request_fun` (test injection).
  """

  @behaviour SymphonyElixir.Forge

  alias SymphonyElixir.Gitlab.Client

  @impl true
  def list_repositories(creds, _opts) do
    with {:ok, projects} <- Client.list_projects(client_opts(creds)) do
      {:ok, Enum.map(projects, &normalize_repo/1)}
    end
  end

  @impl true
  def get_repository(creds, owner, repo) do
    with {:ok, body} <- Client.get_project(owner, repo, client_opts(creds)) do
      {:ok, normalize_repo(body)}
    end
  end

  @impl true
  def list_change_requests(creds, ref, _opts) do
    with {:ok, mrs} <- Client.list_open_merge_requests(ref.owner, ref.repo, client_opts(creds)) do
      {:ok, Enum.map(mrs, &normalize_mr/1)}
    end
  end

  @impl true
  def list_pipeline_runs(creds, ref, head_sha) do
    with {:ok, pipelines} <- Client.list_pipelines(ref.owner, ref.repo, client_opts(creds) ++ [sha: head_sha]) do
      {:ok, Enum.map(pipelines, &normalize_pipeline/1)}
    end
  end

  @impl true
  def get_pipeline_logs(creds, ref, pipeline_id) do
    opts = client_opts(creds)

    with {:ok, jobs} <- Client.list_pipeline_jobs(ref.owner, ref.repo, pipeline_id, opts) do
      traces =
        jobs
        |> Enum.filter(&(&1.status == "failed"))
        |> Enum.map(fn job ->
          case Client.get_job_trace(ref.owner, ref.repo, job.id, opts) do
            {:ok, trace} -> "== job #{job.name} ==\n#{trace}"
            {:error, reason} -> "== job #{job.name} (trace error: #{inspect(reason)}) =="
          end
        end)

      {:ok, Enum.join(traces, "\n\n")}
    end
  end

  @impl true
  def create_comment(creds, ref, mr_iid, body) do
    Client.create_merge_request_note(ref.owner, ref.repo, mr_iid, body, client_opts(creds))
  end

  @impl true
  def create_review(creds, ref, mr_iid, body, _opts) do
    Client.create_merge_request_note(ref.owner, ref.repo, mr_iid, body, client_opts(creds))
  end

  @impl true
  def list_change_request_comments(creds, ref, mr_iid) do
    Client.list_merge_request_notes(ref.owner, ref.repo, mr_iid, client_opts(creds))
  end

  # --- helpers ---

  defp client_opts(creds) do
    []
    |> put_if(creds[:token], :token)
    |> put_if(creds[:base_url], :base_url)
    |> put_if(creds[:request_fun], :request_fun)
  end

  defp put_if(opts, nil, _key), do: opts
  defp put_if(opts, value, key), do: Keyword.put(opts, key, value)

  defp normalize_repo(body) do
    %{
      owner: get_in(body, ["namespace", "full_path"]),
      name: body["path"],
      default_branch: body["default_branch"],
      url: body["web_url"]
    }
  end

  defp normalize_mr(%SymphonyElixir.Gitlab.MergeRequest{} = mr) do
    %{number: mr.number, head_sha: mr.head_sha, head_ref: mr.head_ref, base_ref: mr.base_ref, url: mr.url}
  end

  defp normalize_pipeline(%SymphonyElixir.Gitlab.Pipeline{} = p) do
    %{
      id: p.id,
      name: "pipeline ##{p.id}",
      status: if(p.status in ~w(success failed canceled skipped), do: "completed", else: p.status),
      conclusion: pipeline_conclusion(p.status),
      head_sha: p.sha
    }
  end

  defp pipeline_conclusion("success"), do: "success"
  defp pipeline_conclusion("failed"), do: "failure"
  defp pipeline_conclusion("canceled"), do: "cancelled"
  defp pipeline_conclusion(_other), do: nil
end
```

- [ ] **Step 4: Run the adapter test, expect pass; full suite green; commit**

```bash
mise exec -- mix test test/symphony_elixir/forge/gitlab_test.exs && mise exec -- mix test
git add lib/symphony_elixir/forge/gitlab.ex test/symphony_elixir/forge/gitlab_test.exs
git commit -m "feat(forge): GitLab adapter implementing the Forge behaviour

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `GitlabMrSource` (MR observation)

Mirrors `GithubPrSource`: list open MRs, resolve the Linear link, persist a PR link, emit `gitlab_mr_observed` candidates.

**Files:**
- Create: `lib/symphony_elixir/work_sources/gitlab_mr_source.ex`
- Test: `test/symphony_elixir/gitlab_mr_source_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SymphonyElixir.WorkSources.GitlabMrSourceTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.WorkSources.GitlabMrSource
  alias SymphonyElixir.Gitlab.MergeRequest

  test "fetch_candidates emits a gitlab_mr_observed run per MR" do
    project = %{id: 1, slug: "demo", forge_type: "gitlab", forge_owner: "group", forge_repo: "api", linear_team_key: "ABC"}
    mr = %MergeRequest{number: 5, title: "Fix ABC-1", body: "ABC-1", head_sha: "abc", head_ref: "f", base_ref: "main"}

    opts = [
      list_merge_requests: fn "group", "api", _ -> {:ok, [mr]} end,
      persist_link: fn _attrs -> :ok end
    ]

    assert {:ok, [run]} = GitlabMrSource.fetch_candidates(project, opts)
    assert run.type == "gitlab_mr_observed"
    assert run.forge_pr_number == 5
    assert run.linear_identifier == "ABC-1"
  end
end
```

- [ ] **Step 2: Run it, expect failure**

Run: `mise exec -- mix test test/symphony_elixir/gitlab_mr_source_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the source**

```elixir
defmodule SymphonyElixir.WorkSources.GitlabMrSource do
  @moduledoc "Polls open GitLab merge requests and records durable MR metadata."

  alias SymphonyElixir.{Gitlab, Github, Storage, WorkRun}
  alias SymphonyElixir.Forge.ProjectCreds

  @spec fetch_candidates(term(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    ref = ProjectCreds.repo_ref(project)
    client_opts = ProjectCreds.gitlab_client_opts(project, opts)

    list_merge_requests =
      Keyword.get(opts, :list_merge_requests, fn owner, repo, _call_opts ->
        Gitlab.Client.list_open_merge_requests(owner, repo, client_opts)
      end)

    owner = ref.owner || project_value(project, :forge_owner)
    repo = ref.repo || project_value(project, :forge_repo)

    with {:ok, mrs} <- list_merge_requests.(owner, repo, []) do
      runs =
        Enum.map(mrs, fn mr ->
          link = Github.LinkResolver.resolve(mr, team_keys: List.wrap(project_value(project, :linear_team_key)))
          persist_link(project, mr, link, owner, repo, opts)
          mr_to_candidate(project, mr, link, owner, repo)
        end)

      {:ok, runs}
    end
  end

  defp persist_link(project, mr, link, owner, repo, opts) do
    persist = Keyword.get(opts, :persist_link, &Storage.upsert_pull_request_link/1)

    persist.(%{
      project_id: project_value(project, :id),
      forge_owner: owner,
      forge_repo: repo,
      forge_pr_number: mr.number,
      forge_head_sha: mr.head_sha,
      forge_head_ref: mr.head_ref,
      forge_base_ref: mr.base_ref,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      metadata: %{"title" => mr.title}
    })
  end

  defp mr_to_candidate(project, mr, link, owner, repo) do
    %WorkRun{
      project_slug: project_value(project, :slug),
      type: "gitlab_mr_observed",
      status: "observed",
      forge_owner: owner,
      forge_repo: repo,
      forge_pr_number: mr.number,
      forge_head_sha: mr.head_sha,
      forge_head_ref: mr.head_ref,
      forge_base_ref: mr.base_ref,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      agent_backend: "codex",
      payload: %{merge_request: mr}
    }
  end

  defp project_value(project, key) when is_map(project) do
    Map.get(project, key) || Map.get(project, to_string(key))
  end
end
```

- [ ] **Step 4: Run the test, expect pass; commit**

```bash
mise exec -- mix test test/symphony_elixir/gitlab_mr_source_test.exs
git add lib/symphony_elixir/work_sources/gitlab_mr_source.ex test/symphony_elixir/gitlab_mr_source_test.exs
git commit -m "feat(gitlab): MR observation work source

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `GitlabPipelineSource` (failed-pipeline CI repair)

Mirrors `GithubFailedCiSource`: for each open MR, find failed pipelines for the head SHA, dedupe, attach job-trace logs, set the push policy, emit `ci_fix` candidates.

**Files:**
- Create: `lib/symphony_elixir/work_sources/gitlab_pipeline_source.ex`
- Test: `test/symphony_elixir/gitlab_pipeline_source_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SymphonyElixir.WorkSources.GitlabPipelineSourceTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.WorkSources.GitlabPipelineSource
  alias SymphonyElixir.Gitlab.{MergeRequest, Pipeline}

  test "fetch_candidates emits a ci_fix run for a failed pipeline with log excerpt" do
    project = %{id: 1, slug: "demo", forge_type: "gitlab", forge_owner: "group", forge_repo: "api", forge_base_branch: "main"}
    mr = %MergeRequest{number: 5, head_sha: "abc", head_ref: "f", base_ref: "main", head_repo_full_name: "7", base_repo_full_name: "7"}
    pipeline = %Pipeline{id: 9, status: "failed", sha: "abc"}

    opts = [
      list_merge_requests: fn "group", "api", _ -> {:ok, [mr]} end,
      list_pipelines: fn "group", "api", _ -> {:ok, [pipeline]} end,
      get_pipeline_logs: fn "group", "api", 9, _ -> {:ok, "boom"} end,
      dedupe_seen?: fn _project_id, _key -> false end
    ]

    assert {:ok, [run]} = GitlabPipelineSource.fetch_candidates(project, opts)
    assert run.type == "ci_fix"
    assert run.dedupe_key == "gitlab-ci-fix:group/api:5:abc:9"
    assert run.payload.log_excerpt == "boom"
    assert run.payload.repo_policy == "direct_push_allowed"
  end
end
```

- [ ] **Step 2: Run it, expect failure**

Run: `mise exec -- mix test test/symphony_elixir/gitlab_pipeline_source_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the source**

```elixir
defmodule SymphonyElixir.WorkSources.GitlabPipelineSource do
  @moduledoc "Polls open GitLab MRs and emits failed-pipeline repair work."

  alias SymphonyElixir.{Gitlab, Github, RuntimePolicy, Storage, WorkRun}
  alias SymphonyElixir.Forge.ProjectCreds

  @max_log_excerpt_bytes 12_000

  @spec fetch_candidates(term(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    ref = ProjectCreds.repo_ref(project)
    client_opts = ProjectCreds.gitlab_client_opts(project, opts)

    list_merge_requests =
      Keyword.get(opts, :list_merge_requests, fn owner, repo, _ ->
        Gitlab.Client.list_open_merge_requests(owner, repo, client_opts)
      end)

    list_pipelines =
      Keyword.get(opts, :list_pipelines, fn owner, repo, call_opts ->
        Gitlab.Client.list_pipelines(owner, repo, client_opts ++ call_opts)
      end)

    get_pipeline_logs =
      Keyword.get(opts, :get_pipeline_logs, fn owner, repo, pipeline_id, _ ->
        creds = %{token: client_opts[:token], base_url: client_opts[:base_url], request_fun: client_opts[:request_fun]}
        SymphonyElixir.Forge.Gitlab.get_pipeline_logs(creds, %{owner: owner, repo: repo, base_url: client_opts[:base_url]}, pipeline_id)
      end)

    dedupe_seen? = Keyword.get(opts, :dedupe_seen?, &Storage.dedupe_seen?/2)

    owner = ref.owner || project_value(project, :forge_owner)
    repo = ref.repo || project_value(project, :forge_repo)

    with {:ok, mrs} <- list_merge_requests.(owner, repo, []) do
      Enum.reduce_while(mrs, {:ok, []}, fn mr, {:ok, runs} ->
        case list_pipelines.(owner, repo, sha: mr.head_sha) do
          {:ok, pipelines} ->
            candidates = candidates(project, owner, repo, mr, pipelines, get_pipeline_logs, dedupe_seen?)
            {:cont, {:ok, runs ++ candidates}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp candidates(project, owner, repo, mr, pipelines, get_pipeline_logs, dedupe_seen?) do
    pipelines
    |> Enum.filter(&(&1.status == "failed"))
    |> Enum.reject(&dedupe_seen?.(project_value(project, :id), dedupe_key(owner, repo, mr, &1)))
    |> Enum.map(&build_run(project, owner, repo, mr, &1, get_pipeline_logs))
  end

  defp build_run(project, owner, repo, mr, pipeline, get_pipeline_logs) do
    link = Github.LinkResolver.resolve(mr, team_keys: List.wrap(project_value(project, :linear_team_key)))

    %WorkRun{
      project_slug: project_value(project, :slug),
      type: "ci_fix",
      status: "queued",
      dedupe_key: dedupe_key(owner, repo, mr, pipeline),
      forge_owner: owner,
      forge_repo: repo,
      forge_pr_number: mr.number,
      forge_head_sha: mr.head_sha,
      forge_head_ref: mr.head_ref,
      forge_base_ref: mr.base_ref,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      agent_backend: "codex",
      payload:
        %{
          project_id: project_value(project, :id),
          merge_request: mr,
          pipeline: pipeline,
          repo_policy: repo_policy(project, mr)
        }
        |> Map.merge(log_payload(owner, repo, pipeline, get_pipeline_logs))
    }
  end

  defp log_payload(owner, repo, pipeline, get_pipeline_logs) do
    case get_pipeline_logs.(owner, repo, pipeline.id, []) do
      {:ok, logs} when is_binary(logs) -> %{log_excerpt: excerpt(logs)}
      {:error, reason} -> %{log_fetch_error: inspect(reason)}
      other -> %{log_fetch_error: inspect({:unexpected_log_result, other})}
    end
  end

  defp excerpt(logs) when byte_size(logs) <= @max_log_excerpt_bytes, do: logs
  defp excerpt(logs), do: binary_part(logs, 0, @max_log_excerpt_bytes) <> "\n[truncated]"

  defp repo_policy(project, mr) do
    case RuntimePolicy.RepoPolicy.authorize_push(%{
           head_repo_full_name: mr.head_repo_full_name,
           base_repo_full_name: mr.base_repo_full_name || "#{project_value(project, :forge_owner)}/#{project_value(project, :forge_repo)}",
           head_ref: mr.head_ref,
           base_ref: mr.base_ref || project_value(project, :forge_base_branch),
           protected_branches: List.wrap(project_value(project, :forge_base_branch))
         }) do
      :ok -> "direct_push_allowed"
      {:error, :fork_pr_requires_repair_branch} -> "repair_branch_required"
      {:error, reason} -> "blocked:#{reason}"
    end
  end

  defp dedupe_key(owner, repo, mr, pipeline) do
    "gitlab-ci-fix:#{owner}/#{repo}:#{mr.number}:#{mr.head_sha}:#{pipeline.id}"
  end

  defp project_value(project, key) when is_map(project) do
    Map.get(project, key) || Map.get(project, to_string(key))
  end
end
```

- [ ] **Step 4: Run the test, expect pass; full suite green; commit**

```bash
mise exec -- mix test test/symphony_elixir/gitlab_pipeline_source_test.exs && mise exec -- mix test
git add lib/symphony_elixir/work_sources/gitlab_pipeline_source.ex test/symphony_elixir/gitlab_pipeline_source_test.exs
git commit -m "feat(gitlab): failed-pipeline CI repair work source

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `GitlabReviewRequestSource` (`@hreview` trigger)

Mirrors `GithubReviewRequestSource`: for each open MR, scan notes for the trigger keyword, dedupe, emit `code_review` candidates. Reuses the project's `review` config (trigger/template/version).

**Files:**
- Create: `lib/symphony_elixir/work_sources/gitlab_review_request_source.ex`
- Test: `test/symphony_elixir/gitlab_review_request_source_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SymphonyElixir.WorkSources.GitlabReviewRequestSourceTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.WorkSources.GitlabReviewRequestSource
  alias SymphonyElixir.Gitlab.{MergeRequest, Note}

  test "fetch_candidates emits a code_review run when a note contains the trigger" do
    project = %{id: 1, slug: "demo", forge_type: "gitlab", forge_owner: "group", forge_repo: "api"}
    mr = %MergeRequest{number: 5, head_sha: "abc", head_ref: "f", base_ref: "main"}
    note = %Note{id: 11, body: "please @hreview", author: "dev"}

    opts = [
      list_merge_requests: fn "group", "api", _ -> {:ok, [mr]} end,
      list_notes: fn "group", "api", 5, _ -> {:ok, [note]} end,
      dedupe_seen?: fn _project_id, _key -> false end
    ]

    assert {:ok, [run]} = GitlabReviewRequestSource.fetch_candidates(project, opts)
    assert run.type == "code_review"
    assert run.dedupe_key == "gitlab-review:group/api:5:11:abc:1"
    assert run.payload.trigger_comment_id == 11
  end
end
```

- [ ] **Step 2: Run it, expect failure**

Run: `mise exec -- mix test test/symphony_elixir/gitlab_review_request_source_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the source**

```elixir
defmodule SymphonyElixir.WorkSources.GitlabReviewRequestSource do
  @moduledoc "Polls open GitLab MRs and emits requested code review work from MR notes."

  alias SymphonyElixir.{Gitlab, Github, Storage, WorkRun}
  alias SymphonyElixir.Forge.ProjectCreds

  @default_trigger "@hreview"
  @default_template_version 1
  @default_template """
  Review correctness, tests, maintainability, security, and operational risk.
  Lead with findings ordered by severity. Include concrete file and line references when you can determine them.
  """

  @spec fetch_candidates(term(), keyword()) :: {:ok, [WorkRun.t()]} | {:error, term()}
  def fetch_candidates(project, opts \\ []) do
    ref = ProjectCreds.repo_ref(project)
    client_opts = ProjectCreds.gitlab_client_opts(project, opts)

    list_merge_requests =
      Keyword.get(opts, :list_merge_requests, fn owner, repo, _ ->
        Gitlab.Client.list_open_merge_requests(owner, repo, client_opts)
      end)

    list_notes =
      Keyword.get(opts, :list_notes, fn owner, repo, mr_iid, _ ->
        Gitlab.Client.list_merge_request_notes(owner, repo, mr_iid, client_opts)
      end)

    dedupe_seen? = Keyword.get(opts, :dedupe_seen?, &Storage.dedupe_seen?/2)

    owner = ref.owner || project_value(project, :forge_owner)
    repo = ref.repo || project_value(project, :forge_repo)

    with {:ok, mrs} <- list_merge_requests.(owner, repo, []) do
      Enum.reduce_while(mrs, {:ok, []}, fn mr, {:ok, runs} ->
        case list_notes.(owner, repo, mr.number, []) do
          {:ok, notes} ->
            {:cont, {:ok, runs ++ candidates(project, owner, repo, mr, notes, dedupe_seen?)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp candidates(project, owner, repo, mr, notes, dedupe_seen?) do
    notes
    |> Enum.filter(&trigger_note?(&1, project))
    |> Enum.reject(&dedupe_seen?.(project_value(project, :id), dedupe_key(owner, repo, mr, &1, project)))
    |> Enum.map(&build_run(project, owner, repo, mr, &1))
  end

  defp build_run(project, owner, repo, mr, note) do
    link = Github.LinkResolver.resolve(mr, team_keys: List.wrap(project_value(project, :linear_team_key)))

    %WorkRun{
      project_slug: project_value(project, :slug),
      type: "code_review",
      status: "queued",
      dedupe_key: dedupe_key(owner, repo, mr, note, project),
      forge_owner: owner,
      forge_repo: repo,
      forge_pr_number: mr.number,
      forge_head_sha: mr.head_sha,
      forge_head_ref: mr.head_ref,
      forge_base_ref: mr.base_ref,
      linear_identifier: link && link.identifier,
      linear_url: link && link.url,
      agent_backend: "codex",
      payload: %{
        project_id: project_value(project, :id),
        merge_request: mr,
        trigger_comment: note,
        trigger_comment_id: note.id,
        trigger_comment_author: note.author,
        trigger: review_trigger(project),
        template: review_template(project),
        template_version: review_template_version(project)
      }
    }
  end

  defp trigger_note?(%{body: body}, project) when is_binary(body), do: String.contains?(body, review_trigger(project))
  defp trigger_note?(_note, _project), do: false

  defp dedupe_key(owner, repo, mr, note, project) do
    "gitlab-review:#{owner}/#{repo}:#{mr.number}:#{note.id}:#{mr.head_sha}:#{review_template_version(project)}"
  end

  defp review_trigger(project) do
    case map_get_any(review_config(project), :trigger) do
      t when is_binary(t) and t != "" -> t
      _ -> @default_trigger
    end
  end

  defp review_template(project) do
    case map_get_any(review_config(project), :template) do
      t when is_binary(t) and t != "" -> t
      _ -> @default_template
    end
  end

  defp review_template_version(project) do
    case map_get_any(review_config(project), :template_version) do
      v when is_integer(v) and v > 0 -> v
      v when is_binary(v) -> parse_positive_integer(v, @default_template_version)
      _ -> @default_template_version
    end
  end

  defp review_config(project) do
    case map_get_any(project_value(project, :config), :review) do
      config when is_map(config) -> config
      _ -> %{}
    end
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> default
    end
  end

  defp project_value(project, key) when is_map(project), do: Map.get(project, key) || Map.get(project, to_string(key))

  defp map_get_any(%{} = map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_get_any(_map, _key), do: nil
end
```

- [ ] **Step 4: Run the test, expect pass; commit**

```bash
mise exec -- mix test test/symphony_elixir/gitlab_review_request_source_test.exs
git add lib/symphony_elixir/work_sources/gitlab_review_request_source.ex test/symphony_elixir/gitlab_review_request_source_test.exs
git commit -m "feat(gitlab): @hreview MR-note review-request work source

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `forge_type` dispatch wrapper in the orchestrator

The three GitHub work-source fetchers become forge-aware: for a `forge_type: "gitlab"` project they call the GitLab source, else GitHub. Injection keys are unchanged (tests keep overriding them).

**Files:**
- Modify: `lib/symphony_elixir/orchestrator.ex` (alias line 14; fetcher helpers 480-494)
- Test: `test/symphony_elixir/orchestrator_status_test.exs` (add a focused test)

- [ ] **Step 1: Write the failing test** — add to `test/symphony_elixir/orchestrator_status_test.exs` (use the module's existing setup conventions for `Application.put_env`/`on_exit` cleanup):

```elixir
test "github_pr fetcher dispatches gitlab projects to the GitLab MR source" do
  fetcher = SymphonyElixir.Orchestrator.github_pr_work_source_fetcher_for_test()

  github_project = %{forge_type: "github", slug: "gh", forge_owner: "o", forge_repo: "r"}
  gitlab_project = %{forge_type: "gitlab", slug: "gl", forge_owner: "g", forge_repo: "a"}

  assert {:ok, _} = override_and_call(fetcher, github_project)
  assert {:ok, _} = override_and_call(fetcher, gitlab_project)
end
```

Note for the implementer: rather than exposing a private fetcher, prefer asserting dispatch through the public poll path with seeded `Forge.Memory` / injected `:list_merge_requests`. If a direct unit test is easier, add a thin test-only accessor. Keep whichever matches the existing test style in this file.

- [ ] **Step 2: Run it, expect failure**

Run: `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
Expected: FAIL — gitlab projects currently route to the GitHub source (wrong source called).

- [ ] **Step 3: Add the GitLab sources to the alias** — `lib/symphony_elixir/orchestrator.ex:14`:

```elixir
  alias SymphonyElixir.WorkSources.{
    GithubFailedCiSource,
    GithubPrSource,
    GithubReviewRequestSource,
    GitlabMrSource,
    GitlabPipelineSource,
    GitlabReviewRequestSource,
    LinearIssueSource
  }
```

- [ ] **Step 4: Wrap each fetcher by `forge_type`** — replace the three helpers (lines 480-494):

```elixir
  defp github_pr_work_source_fetcher do
    Application.get_env(
      :symphony_elixir,
      :github_pr_work_source_fetcher,
      by_forge_type(&GithubPrSource.fetch_candidates/1, &GitlabMrSource.fetch_candidates/1)
    )
  end

  defp github_ci_work_source_fetcher do
    Application.get_env(
      :symphony_elixir,
      :github_ci_work_source_fetcher,
      by_forge_type(&GithubFailedCiSource.fetch_candidates/1, &GitlabPipelineSource.fetch_candidates/1)
    )
  end

  defp github_review_work_source_fetcher do
    Application.get_env(
      :symphony_elixir,
      :github_review_work_source_fetcher,
      by_forge_type(&GithubReviewRequestSource.fetch_candidates/1, &GitlabReviewRequestSource.fetch_candidates/1)
    )
  end

  defp by_forge_type(github_fun, gitlab_fun) do
    fn project ->
      case project_value(project, :forge_type) do
        "gitlab" -> gitlab_fun.(project)
        _ -> github_fun.(project)
      end
    end
  end
```

(`project_value/2` already exists in the orchestrator — used by `linear_work_source_fetcher`. Reuse it.)

- [ ] **Step 5: Run the test, expect pass; full suite green; commit**

```bash
mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs && mise exec -- mix test
git add lib/symphony_elixir/orchestrator.ex test/symphony_elixir/orchestrator_status_test.exs
git commit -m "feat(orchestrator): dispatch work sources by project forge_type

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: End-to-end GitLab dispatch test + gates

Proves a `forge_type: "gitlab"` project flows through the poll path to the GitLab sources and produces persisted work runs, then runs the full quality gates.

**Files:**
- Test: `test/symphony_elixir/gitlab_end_to_end_test.exs`

- [ ] **Step 1: Write the end-to-end test** — drive the orchestrator's project-sources path with a seeded GitLab project and injected fetchers (mirror how `orchestrator_status_test.exs` injects `:project_fetcher` and the `*_work_source_fetcher` keys, with `on_exit` cleanup):

```elixir
defmodule SymphonyElixir.GitlabEndToEndTest do
  use SymphonyElixir.DataCase, async: false
  alias SymphonyElixir.Gitlab.MergeRequest

  test "a gitlab project's open MR becomes a persisted observation run" do
    project = %{id: 1, slug: "gl-demo", forge_type: "gitlab", forge_owner: "group", forge_repo: "api", linear_team_key: "ABC"}
    mr = %MergeRequest{number: 5, title: "Fix ABC-1", body: "ABC-1", head_sha: "abc", head_ref: "f", base_ref: "main"}

    Application.put_env(:symphony_elixir, :project_fetcher, fn -> [project] end)

    Application.put_env(:symphony_elixir, :github_pr_work_source_fetcher, fn proj ->
      SymphonyElixir.WorkSources.GitlabMrSource.fetch_candidates(proj,
        list_merge_requests: fn "group", "api", _ -> {:ok, [mr]} end,
        persist_link: fn _ -> :ok end
      )
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :project_fetcher)
      Application.delete_env(:symphony_elixir, :github_pr_work_source_fetcher)
    end)

    assert {:ok, _} = SymphonyElixir.Orchestrator.fetch_and_persist_project_work()
    runs = SymphonyElixir.Storage.list_work_runs_by_project_slug("gl-demo")
    assert Enum.any?(runs, &(&1.type == "gitlab_mr_observed" and &1.forge_pr_number == 5))
  end
end
```

Note for the implementer: use the **actual** public entry point this codebase exposes for one poll cycle of project sources (grep the orchestrator for the function `fetch_from_project_sources/1`'s caller, e.g. a `fetch_and_persist_project_work/0`-style function or the GenServer `handle_info` poll). Use the real `Storage` list function for runs by project slug (grep `def list_work_runs`). Adjust names to what exists; keep the assertion (a `gitlab_mr_observed` run for MR #5 is persisted).

- [ ] **Step 2: Run it, expect pass**

Run: `mise exec -- mix test test/symphony_elixir/gitlab_end_to_end_test.exs`
Expected: PASS.

- [ ] **Step 3: Run all quality gates**

```bash
mise exec -- mix format --check-formatted
mise exec -- mix specs.check
mise exec -- mix test
```
Expected: all exit 0. (If `mix specs.check` flags the new modules, add `@spec`s to the public functions to match the codebase convention, then re-run.)

- [ ] **Step 4: Commit**

```bash
git add test/symphony_elixir/gitlab_end_to_end_test.exs
git commit -m "test(gitlab): end-to-end dispatch of a gitlab project's MR observation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- New modules (Forge.Gitlab, Gitlab.Client, structs, 3 work sources) → Tasks 3–8. ✓
- GitLab→GitHub mapping (iid→number, namespace path, pipelines/jobs/trace, notes) → Tasks 3–5, 7, 8. ✓
- `forge_type` dispatch wrapper → Task 9. ✓
- `list_change_request_comments` behaviour extension on both adapters → Tasks 1 (GitHub+Memory) & 5 (GitLab). ✓
- Credentials via global `GITLAB_TOKEN`, no new migration → Task 2 + Task 4 (`token/1`). ✓
- Self-host via `instance_url`/`forge_base_url` → Task 4 (`api_root/1`), Task 5. ✓
- Handoffs forge-neutral (discovered refinement: spec said "already routed"; they call `Forge.Github.*` directly) → Task 2. ✓
- Testing: fixtures via `request_fun`, Memory adapter, e2e → throughout + Task 10. ✓
- Out of scope honored: no webhooks, no per-project secrets, no picker, no API rename, no MR-approval. ✓

**Placeholder scan:** No "TBD"/"implement later". Two tasks (9, 10) carry explicit implementer notes to match exact existing function names (orchestrator poll entry, `Storage` list-by-slug) because those names must be grepped from the live code rather than guessed — the assertion and intent are fully specified.

**Type consistency:** Struct field names (`number`, `head_sha`, `head_ref`, `base_ref`, `head_repo_full_name`, `base_repo_full_name`, `project_id`) are used identically across Tasks 3, 6, 7, 8. Client function names (`list_open_merge_requests`, `list_pipelines`, `list_pipeline_jobs`, `get_job_trace`, `list_merge_request_notes`, `create_merge_request_note`) are used identically in Tasks 4, 5. Adapter callback set matches the behaviour after Task 1 adds `list_change_request_comments`. `gitlab_client_opts/2` (Task 2) is consumed by Tasks 6–8. Dedupe-key formats (`gitlab-ci-fix:`, `gitlab-review:`) are self-consistent.

**Risk note for the implementer:** GitLab REST field names (`sha` vs `diff_refs.head_sha`, `description` as body, `namespace.full_path`) are encoded from the documented v4 API; if a recorded fixture from the target instance differs, adjust `from_api/1` and its test together (TDD catches this on first real fixture).
