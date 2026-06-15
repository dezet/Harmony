# Complete Interactive Review (follow-ups) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the three review v1 gaps — per-project bot identity (I3), A3 verification + bounded retry (V3), and B3 webhook nudges for both forges (W2).

**Architecture:** Phase 1 adds a `Forge.current_user/1` callback and a `Review.Identity` resolver (config → whoami-cache → default), wired into both review-response sources. Phase 2 grows the agent's structured output with `files_changed`, guards resolve on `resolved ∧ path ∈ files_changed`, and adds a per-thread retry cap (3) backed by the dedupe store. Phase 3 adds GitHub review events to the existing webhook controller and a new GitLab webhook controller — both as refresh nudges, the polling source staying the single source of truth.

**Tech Stack:** Elixir, Phoenix, Ecto; Req; ExUnit.

**Spec:** `docs/superpowers/specs/2026-06-15-review-followups-design.md`

**Base:** branch `feat/review-followups` off `main` (which already has review v1 / PR #13).

**Environment (every task):** run from `elixir/`; prefix every `mix` command with `export CLOAK_KEY="$(openssl rand -base64 32)"` (Phase-2 fail-fast boot). Postgres is the podman container `harmony-postgres` on 5432.

**Conventions to mirror (read before coding):**
- `lib/symphony_elixir/forge/memory.ex` — Agent-backed adapter (`seed_*`, `record_call`, `@impl`).
- `lib/symphony_elixir/forge/github.ex` + `gitlab.ex` — `client_opts(creds)`, REST/GraphQL request seam via `request_fun`.
- `lib/symphony_elixir/work_sources/github_review_response_source.ex` + `gitlab_review_response_source.ex` — the sources to modify (identity at `@default_identity`/line ~20, per-thread `dedupe_key`).
- `lib/symphony_elixir/workflows/address_review_handoff.ex` + `address_review_prompt.ex` — the A3 targets.
- `lib/symphony_elixir/storage.ex` — `dedupe_seen?/2`, `dedupe_status/3`, `mark_dedupe_processed/1`, `mark_dedupe_claimed/1`; `DedupeKey` schema has `status` + `metadata`.
- `lib/symphony_elixir_web/controllers/github_webhook_controller.ex` — `@supported_events`, secret check, `append_webhook_event` + refresh; `lib/symphony_elixir_web/router.ex` — the webhook route.

---

## File Structure

**Phase 1 (identity)**
- Modify `lib/symphony_elixir/forge.ex` — `current_user/1` callback.
- Modify `forge/memory.ex`, `forge/github.ex`, `forge/gitlab.ex` — implement `current_user`.
- Create `lib/symphony_elixir/review/identity.ex` — the resolver + token cache.
- Modify both review-response sources — use `Review.Identity.resolve/3`.

**Phase 2 (A3)**
- Modify `workflows/address_review_prompt.ex` — request `files_changed`.
- Modify `workflows/address_review_handoff.ex` — parse `files_changed`, guard resolve, per-thread mark + retry cap, "needs human" note.
- Modify `storage.ex` — read/increment a per-key attempt count (in `DedupeKey.metadata`).
- Modify both review-response sources — skip processed/capped threads (per-thread, already per-thread in selection).

**Phase 3 (B3)**
- Modify `controllers/github_webhook_controller.ex` — add the two review events.
- Create `controllers/gitlab_webhook_controller.ex` + route in `router.ex`.

---

## Task 1: `Forge.current_user/1` + adapters

**Files:** `lib/symphony_elixir/forge.ex`, `forge/memory.ex`, `forge/github.ex`, `forge/gitlab.ex`; test `test/symphony_elixir/forge_current_user_test.exs`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SymphonyElixir.ForgeCurrentUserTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Forge.{Memory, Github, Gitlab}

  setup do
    Memory.reset()
    :ok
  end

  test "memory current_user returns the seeded login" do
    Memory.seed_current_user("harmony[bot]")
    assert {:ok, "harmony[bot]"} = Memory.current_user(%{})
  end

  test "github current_user reads .login from GET /user" do
    request_fun = fn _req -> {:ok, %Req.Response{status: 200, body: %{"login" => "harmony[bot]"}}} end
    assert {:ok, "harmony[bot]"} = Github.current_user(%{token: "t", base_url: nil, request_fun: request_fun})
  end

  test "gitlab current_user reads .username from GET /user" do
    request_fun = fn _req -> {:ok, %Req.Response{status: 200, body: %{"username" => "harmony-bot"}}} end
    assert {:ok, "harmony-bot"} = Gitlab.current_user(%{token: "t", base_url: nil, request_fun: request_fun})
  end
end
```

- [ ] **Step 2: Run it (fails)** — `mix test test/symphony_elixir/forge_current_user_test.exs` → FAIL (undefined).

- [ ] **Step 3: Add the callback**

In `forge.ex`, after the review-thread callbacks:

```elixir
  @callback current_user(creds) :: {:ok, String.t()} | {:error, term()}
```

- [ ] **Step 4: Implement the adapters**

`forge/memory.ex`: add `current_user: nil` to `initial_state/0`, a `seed_current_user/1` seeder (mirror `seed_review_threads/1`), and:

```elixir
  @impl SymphonyElixir.Forge
  def current_user(creds) do
    record_call(:current_user, [creds])
    {:ok, Agent.get(@agent, & &1.current_user)}
  end
```

`forge/github.ex` — mirror the REST callbacks (use the same `Github.Client` GET seam the other callbacks use; the client's `request_fun`/`headers(token)` pattern). Add a `Github.Client.get_authenticated_user/1` if the client has no `/user` fn, OR call the existing request helper directly:

```elixir
  @impl true
  def current_user(creds) do
    case Github.Client.get_authenticated_user(client_opts(creds)) do
      {:ok, %{"login" => login}} when is_binary(login) -> {:ok, login}
      {:ok, _} -> {:error, :no_login}
      {:error, reason} -> {:error, reason}
    end
  end
```

`forge/gitlab.ex` — same shape via `Gitlab.Client.get_authenticated_user/1` reading `"username"`.

> Verify against real client code: confirm the exact GET helper/idiom in `github/client.ex` and `gitlab/client.ex` (they expose `request_fun`, `api_root/1`, `headers/1`). Add a thin `get_authenticated_user/1` to each client that GETs `{api_root}/user` and returns the decoded body, mirroring an existing GET function. Match the real request_fun call convention (GitHub passes a `%Req.Request{}` for GraphQL but keyword lists for REST; GitLab passes keyword lists — follow each client's REST idiom for the `/user` GET).

- [ ] **Step 5: Run it (passes)** — `mix test test/symphony_elixir/forge_current_user_test.exs` → PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/symphony_elixir/forge.ex lib/symphony_elixir/forge/*.ex lib/symphony_elixir/github/client.ex lib/symphony_elixir/gitlab/client.ex test/symphony_elixir/forge_current_user_test.exs
git commit -m "feat(review): Forge.current_user across adapters"
```

---

## Task 2: `Review.Identity` resolver + wire sources

**Files:** create `lib/symphony_elixir/review/identity.ex`; modify both review-response sources; test `test/symphony_elixir/review_identity_test.exs`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SymphonyElixir.ReviewIdentityTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Review.Identity

  setup do
    Identity.reset_cache()
    :ok
  end

  test "config bot_identity wins without any whoami call" do
    project = %{forge_type: "github", config: %{"review" => %{"bot_identity" => "cfg-bot"}}}
    whoami = fn _ -> raise "should not be called" end
    assert "cfg-bot" = Identity.resolve(project, %{token: "t"}, current_user: whoami)
  end

  test "falls back to whoami when no config, and caches by token" do
    project = %{forge_type: "github", config: %{}}
    pid = self()
    whoami = fn _ -> send(pid, :called); {:ok, "api-bot"} end

    assert "api-bot" = Identity.resolve(project, %{token: "tok"}, current_user: whoami)
    assert "api-bot" = Identity.resolve(project, %{token: "tok"}, current_user: whoami)
    assert_received :called
    refute_received :called  # second call served from cache
  end

  test "whoami error falls back to default harmony" do
    project = %{forge_type: "github", config: %{}}
    whoami = fn _ -> {:error, :boom} end
    assert "harmony" = Identity.resolve(project, %{token: "t2"}, current_user: whoami)
  end
end
```

- [ ] **Step 2: Run it (fails)** — FAIL (module undefined).

- [ ] **Step 3: Implement the resolver**

Create `lib/symphony_elixir/review/identity.ex`:

```elixir
defmodule SymphonyElixir.Review.Identity do
  @moduledoc """
  Resolves the Harmony bot login used to skip the bot's own review replies:
  project config `review.bot_identity` → forge whoami (cached per token) → "harmony".
  """

  @default "harmony"
  @table :review_identity_cache

  @spec resolve(map(), map(), keyword()) :: String.t()
  def resolve(project, creds, opts \\ []) do
    case config_identity(project) do
      identity when is_binary(identity) and identity != "" -> identity
      _ -> whoami_or_default(creds, opts)
    end
  end

  @spec reset_cache() :: :ok
  def reset_cache do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp config_identity(project) do
    project
    |> mget(:config)
    |> case do
      %{} = cfg -> cfg |> mget("review") |> mget("bot_identity")
      _ -> nil
    end
  end

  defp whoami_or_default(creds, opts) do
    token = Map.get(creds, :token)
    ensure_table()

    case token && :ets.lookup(@table, token) do
      [{^token, login}] ->
        login

      _ ->
        current_user = Keyword.get(opts, :current_user, fn c -> default_current_user(c) end)

        case current_user.(creds) do
          {:ok, login} when is_binary(login) and login != "" ->
            if token, do: :ets.insert(@table, {token, login})
            login

          _ ->
            @default
        end
    end
  end

  defp default_current_user(_creds), do: {:error, :not_wired}

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp mget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp mget(_map, _key), do: nil
end
```

> The default `current_user` is wired by the caller (the work source passes `current_user: fn creds -> Forge.adapter(project).current_user(creds) end`), so `Identity` does not depend on `Forge` directly and stays unit-testable. Confirm `:ets` table lifecycle is safe under the test suite (named public table created lazily; `reset_cache/0` clears it).

- [ ] **Step 4: Wire both sources**

In `github_review_response_source.ex` and `gitlab_review_response_source.ex`, replace the identity line:

```elixir
    identity =
      Keyword.get(opts, :harmony_identity) ||
        SymphonyElixir.Review.Identity.resolve(project, creds,
          current_user: fn c -> SymphonyElixir.Forge.adapter(project).current_user(c) end
        )
```

(Keep the `:harmony_identity` opt override so existing tests that pass it still work.)

- [ ] **Step 5: Run it (passes) + source tests**

`mix test test/symphony_elixir/review_identity_test.exs test/symphony_elixir/review_response_source_test.exs` → PASS (the existing source test passes `harmony_identity:` so it is unaffected).

- [ ] **Step 6: Commit**

```bash
git add lib/symphony_elixir/review/identity.ex lib/symphony_elixir/work_sources/*review_response_source.ex test/symphony_elixir/review_identity_test.exs
git commit -m "feat(review): per-project bot identity resolver (config → whoami → default)"
```

---

## Task 3: A3 — `files_changed` contract + resolve guard

**Files:** `workflows/address_review_prompt.ex`, `workflows/address_review_handoff.ex`; test `test/symphony_elixir/address_review_handoff_test.exs` (extend).

- [ ] **Step 1: Write the failing tests** (append to the existing handoff test module)

```elixir
  @body_guarded """
  done.
  {"threads": [{"thread_id": "T1", "reply": "fixed", "resolved": true},
               {"thread_id": "T2", "reply": "n/a", "resolved": true}],
   "files_changed": ["lib/a.ex"]}
  """

  test "resolves only threads whose path was changed" do
    run = %WorkRun{type: "address_review", forge_owner: "o", forge_repo: "r", forge_pr_number: 7,
      dedupe_key: "k", payload: %{"project_id" => "p1",
      "threads" => [%{id: "T1", path: "lib/a.ex"}, %{id: "T2", path: "lib/b.ex"}]}}

    test_pid = self()
    opts = [
      reply: fn _ref, _c, tid, _b -> send(test_pid, {:reply, tid}); :ok end,
      resolve: fn _ref, _c, tid -> send(test_pid, {:resolve, tid}); :ok end,
      append_event: fn _ -> :ok end, mark_dedupe_processed: fn _ -> :ok end
    ]

    assert :ok = AddressReviewHandoff.publish(run, @body_guarded, opts)
    assert_received {:reply, "T1"}
    assert_received {:reply, "T2"}
    assert_received {:resolve, "T1"}
    refute_received {:resolve, "T2"}   # path lib/b.ex not in files_changed → not resolved
  end
```

> The handoff needs each thread's `path`. v1's handoff worked off the agent JSON only; now it must
> map `thread_id → path` from `run.payload["threads"]`. Pass the run's threads into the decision merge.

- [ ] **Step 2: Run it (fails)** — the new test fails (T2 gets resolved today; no path guard).

- [ ] **Step 3: Update the prompt**

In `address_review_prompt.ex`, change the contract line to also ask for `files_changed`:

```
    {"threads": [{"thread_id": "<id>", "reply": "<reply>", "resolved": true}], "files_changed": ["<path>", ...]}

    Resolve a thread only if you actually changed the file it is anchored to; list every file you
    edited in "files_changed".
```

(Add a brief assertion to the prompt test that the output mentions `files_changed`.)

- [ ] **Step 4: Update the handoff**

In `address_review_handoff.ex`:
- Parse `files_changed` (default `[]`) alongside `threads`.
- Build a `thread_id → path` map from `run.payload["threads"]` (string OR atom keys).
- Per decision: always `reply`; `resolve` iff `decision.resolved and path_in_changed?(path, files_changed)`.

```elixir
  defp parse_decisions(body) do
    with [_ | _] = matches <- Regex.scan(~r/\{.*"threads".*\}/s, body),
         json <- matches |> List.last() |> List.first(),
         {:ok, %{"threads" => threads} = decoded} when is_list(threads) <- Jason.decode(json) do
      files = Map.get(decoded, "files_changed", [])
      {:ok, Enum.map(threads, &normalize_decision/1), (is_list(files) && files) || []}
    else
      _ -> {:error, :no_structured_output}
    end
  end
```

The `apply_decisions` loop gains `files_changed` + the path map and guards resolve:

```elixir
  defp maybe_resolve(%{resolved: true} = d, paths, files, ref, change_id, resolve) do
    path = Map.get(paths, d.thread_id)
    if path && path in files, do: resolve.(ref, change_id, d.thread_id), else: :ok
  end
  defp maybe_resolve(_d, _paths, _files, _ref, _change_id, _resolve), do: :ok
```

where `paths` is `run.payload["threads"] |> Map.new(fn t -> {tid(t), tpath(t)} end)` (handle string/atom keys via the existing `pv/2`-style getter).

> Keep `publish/3`'s signature and the existing injected `reply`/`resolve` arities unchanged. The dedupe-marking change (resolve-gated) lands in Task 4 — for Task 3, keep the existing "mark processed after the loop" behavior so the test stays focused on the resolve guard.

- [ ] **Step 5: Run it (passes)** — `mix test test/symphony_elixir/address_review_handoff_test.exs test/symphony_elixir/address_review_prompt_test.exs` → PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/symphony_elixir/workflows/address_review_prompt.ex lib/symphony_elixir/workflows/address_review_handoff.ex test/symphony_elixir/address_review_handoff_test.exs test/symphony_elixir/address_review_prompt_test.exs
git commit -m "feat(review): A3 resolve guard — resolve only files the agent changed"
```

---

## Task 4: A3 — per-thread retry cap + needs-human

**Files:** `storage.ex`, `workflows/address_review_handoff.ex`, both review-response sources; test `test/symphony_elixir/review_retry_cap_test.exs`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SymphonyElixir.ReviewRetryCapTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Storage, WorkRun}
  alias SymphonyElixir.Workflows.AddressReviewHandoff

  @run %WorkRun{type: "address_review", forge_owner: "o", forge_repo: "r", forge_pr_number: 7,
    dedupe_key: "review-response:o/r:7:T1:C1",
    payload: %{"project_id" => "p1", "threads" => [%{id: "T1", path: "lib/a.ex"}]}}

  # Agent claims resolved but does NOT change the file → thread stays open, attempt increments.
  @unaddressed ~s({"threads":[{"thread_id":"T1","reply":"hmm","resolved":true}],"files_changed":[]})

  @tag :db
  test "an unaddressed thread is left open and its attempt count increments" do
    :ok = checkout_repo(%{})
    recorded = fn _ref, _c, _t -> :ok end
    opts = [reply: recorded, resolve: fn _r, _c, _t -> :ok end]

    assert :ok = AddressReviewHandoff.publish(@run, @unaddressed, opts)
    assert Storage.dedupe_status("p1", @run.dedupe_key) != "processed"
    assert Storage.review_attempt_count("p1", @run.dedupe_key) == 1
  end

  @tag :db
  test "reaching 3 attempts marks processed and posts a needs-human note" do
    :ok = checkout_repo(%{})
    test_pid = self()
    opts = [reply: fn _ref, _c, _t, b -> send(test_pid, {:reply, b}); :ok end, resolve: fn _r, _c, _t -> :ok end]

    for _ <- 1..3, do: AddressReviewHandoff.publish(@run, @unaddressed, opts)

    assert Storage.dedupe_status("p1", @run.dedupe_key) == "processed"
    assert_received {:reply, body} when is_binary(body)
    # the last reply on the 3rd attempt is the needs-human note
  end
end
```

- [ ] **Step 2: Run it (fails)** — `Storage.review_attempt_count/2` undefined; cap logic absent.

- [ ] **Step 3: Add the Storage helper**

In `storage.ex`, add a reader for the per-key attempt count stored in `DedupeKey.metadata["review_attempts"]`, plus an incrementer:

```elixir
  @spec review_attempt_count(binary(), String.t()) :: non_neg_integer()
  def review_attempt_count(project_id, key) when is_binary(project_id) and is_binary(key) do
    case Repo.get_by(DedupeKey, project_id: project_id, dedupe_key: key) do
      %DedupeKey{metadata: %{"review_attempts" => n}} when is_integer(n) -> n
      _ -> 0
    end
  end

  @spec increment_review_attempt(binary(), String.t()) :: {:ok, non_neg_integer()}
  def increment_review_attempt(project_id, key) when is_binary(project_id) and is_binary(key) do
    n = review_attempt_count(project_id, key) + 1

    mark_dedupe_claimed(%{
      project_id: project_id, key: key, scope: "review_response",
      status: "attempting", metadata: %{"review_attempts" => n}
    })

    {:ok, n}
  end
```

> Verify `mark_dedupe_claimed/1`'s exact arg map shape and that it upserts metadata (read its impl); if it does not merge metadata, adjust to write the count. Confirm `DedupeKey` aliased in `storage.ex`.

- [ ] **Step 4: Update the handoff to gate marking on resolution + cap**

Replace the handoff's terminal marking. After `apply_decisions` returns per-thread outcomes, for the run's threads:
- resolved threads → `mark_processed` their key.
- an unresolved thread → `increment_review_attempt`; if the new count `>= 3`, post a needs-human note via `reply` and `mark_processed` (terminal); else leave it (re-poll).

```elixir
  @max_attempts 3

  defp finalize_thread(outcome, run, reply, opts) do
    key = run.dedupe_key   # one thread per key in the per-thread model; see note
    cond do
      outcome.resolved -> mark_processed(run, opts)
      true ->
        {:ok, n} = increment_review_attempt(project_id(run), key)
        if n >= @max_attempts do
          reply.(ref(run), run.forge_pr_number, outcome.thread_id,
            "Harmony could not resolve this after #{@max_attempts} attempts — needs human review.")
          mark_processed(run, opts)
        else
          :ok
        end
    end
  end
```

> NOTE on granularity: v1 emits one run per CR carrying *all* actionable threads with a single
> `dedupe_key` (last thread's). For per-thread retry to be correct, the run must carry the key per
> thread. Simplest faithful change: have the source set `dedupe_key` per the FIRST actionable thread
> and include each thread's own key in `payload["threads"][i]["dedupe_key"]`, then the handoff
> finalizes each thread by its own key. Implement that mapping in Task 4 (source: add `dedupe_key`
> per thread entry; handoff: finalize per entry). Keep the run-level `dedupe_key` for claim/dispatch.

- [ ] **Step 5: Update both sources for per-thread keys + cap skip**

In both sources' `build_run`, add each thread's own dedupe key into its payload entry, and in the
selection (`Enum.reject`) also skip threads at/over the cap:

```elixir
    actionable =
      threads
      |> Enum.filter(&actionable_thread?(&1, identity))
      |> Enum.reject(fn t ->
        key = dedupe_key(owner, repo, pr, t)
        dedupe_seen?.(pv(project, :id), key) or
          Storage.review_attempt_count(pv(project, :id), key) >= 3
      end)
      |> Enum.map(fn t -> Map.put(t, :dedupe_key, dedupe_key(owner, repo, pr, t)) end)
```

> Keep the `dedupe_seen?` injection seam; add `review_attempt_count` with a default to `Storage`
> (tests that stub `dedupe_seen?` and don't touch the DB still pass — guard the cap check behind the
> same DB availability as the source's other Storage calls, or inject it too).

- [ ] **Step 6: Run it (passes) + source tests** — `mix test test/symphony_elixir/review_retry_cap_test.exs test/symphony_elixir/review_response_source_test.exs test/symphony_elixir/address_review_handoff_test.exs` → PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/symphony_elixir/storage.ex lib/symphony_elixir/workflows/address_review_handoff.ex lib/symphony_elixir/work_sources/*review_response_source.ex test/symphony_elixir/review_retry_cap_test.exs
git commit -m "feat(review): A3 per-thread retry cap (3) + needs-human handoff"
```

---

## Task 5: B3 — GitHub review webhook events

**Files:** `controllers/github_webhook_controller.ex`; test `test/symphony_elixir/github_webhook_test.exs` (extend).

- [ ] **Step 1: Write the failing test** — assert a `pull_request_review_comment` event is accepted (not "ignored"). Mirror the existing accepted-event test in `github_webhook_test.exs` (find how it posts an event with the `x-github-event` header and asserts `status: "accepted"`), swapping the event name.

- [ ] **Step 2: Run it (fails)** — the event is currently "ignored" (not in `@supported_events`).

- [ ] **Step 3: Implement**

In `github_webhook_controller.ex`, extend the constant:

```elixir
  @supported_events MapSet.new([
    "pull_request",
    "issue_comment",
    "workflow_run",
    "pull_request_review",
    "pull_request_review_comment"
  ])
```

- [ ] **Step 4: Run it (passes)** — `mix test test/symphony_elixir/github_webhook_test.exs` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir_web/controllers/github_webhook_controller.ex test/symphony_elixir/github_webhook_test.exs
git commit -m "feat(review): nudge on GitHub review webhook events"
```

---

## Task 6: B3 — GitLab webhook controller

**Files:** create `controllers/gitlab_webhook_controller.ex`; modify `router.ex`; test `test/symphony_elixir/gitlab_webhook_test.exs`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SymphonyElixir.GitlabWebhookTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    start_test_endpoint()
    Application.put_env(:symphony_elixir, :gitlab_webhook_secret, "s3cret")
    on_exit(fn -> Application.delete_env(:symphony_elixir, :gitlab_webhook_secret) end)
    :ok
  end

  defp post_hook(token, event, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-gitlab-token", token)
    |> put_req_header("x-gitlab-event", event)
    |> post("/api/v1/gitlab/webhook", Jason.encode!(body))
  end

  @tag :db
  test "accepts a valid token + Note Hook" do
    :ok = checkout_repo(%{})
    conn = post_hook("s3cret", "Note Hook", %{"object_kind" => "note"})
    assert json_response(conn, 200)["status"] == "accepted"
  end

  test "rejects a bad token with 401" do
    conn = post_hook("wrong", "Note Hook", %{})
    assert json_response(conn, 401)["error"]["code"] == "invalid_token"
  end

  test "ignores an unsupported event" do
    conn = post_hook("s3cret", "Pipeline Hook", %{})
    assert json_response(conn, 200)["status"] == "ignored"
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
```

- [ ] **Step 2: Run it (fails)** — no route/controller.

- [ ] **Step 3: Implement the controller**

Create `lib/symphony_elixir_web/controllers/gitlab_webhook_controller.ex`, mirroring `GithubWebhookController` (read it for the exact `append_webhook_event`/refresh helpers and reuse them):

```elixir
defmodule SymphonyElixirWeb.GitlabWebhookController do
  @moduledoc "GitLab webhook receiver: review/MR events nudge a project refresh."
  use Phoenix.Controller, formats: [:json]
  alias Plug.Conn

  @supported MapSet.new(["Note Hook", "Merge Request Hook"])

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    with :ok <- verify_token(conn),
         {:ok, event} <- gitlab_event(conn) do
      if MapSet.member?(@supported, event) do
        _ = nudge_refresh(params, event, conn)
        json(conn, %{status: "accepted", event: event})
      else
        json(conn, %{status: "ignored", event: event})
      end
    end
  end

  defp verify_token(conn) do
    secret = Application.get_env(:symphony_elixir, :gitlab_webhook_secret)
    header = conn |> Conn.get_req_header("x-gitlab-token") |> List.first()

    cond do
      is_nil(secret) or secret == "" -> {:error, conn |> put_status(401) |> json(%{error: %{code: "invalid_token"}})}
      Plug.Crypto.secure_compare(to_string(header), secret) -> :ok
      true -> {:error, conn |> put_status(401) |> json(%{error: %{code: "invalid_token"}})}
    end
  end

  defp gitlab_event(conn) do
    case conn |> Conn.get_req_header("x-gitlab-event") |> List.first() do
      e when is_binary(e) and e != "" -> {:ok, e}
      _ -> {:error, conn |> put_status(400) |> json(%{error: %{code: "missing_event"}})}
    end
  end

  # Reuse the GitHub controller's refresh approach: append a webhook event + trigger a refresh.
  defp nudge_refresh(_params, _event, _conn), do: :ok
end
```

> Read `github_webhook_controller.ex` and replicate its REAL refresh path (it calls something like
> `append_webhook_event/4` + `Presenter.refresh_payload(orchestrator())`). Replace the stub
> `nudge_refresh/3` with the same mechanism so a GitLab nudge triggers the same refresh as GitHub's.
> The `with` returning a `{:error, conn}` must render that conn — match how `FallbackController` or the
> GitHub controller returns error conns (the GitHub controller returns the conn directly; do the same).

- [ ] **Step 4: Add the route**

In `router.ex`, next to the GitHub webhook route:

```elixir
    post("/api/v1/gitlab/webhook", GitlabWebhookController, :create)
    match(:*, "/api/v1/gitlab/webhook", ObservabilityApiController, :method_not_allowed)
```

- [ ] **Step 5: Run it (passes)** — `mix test test/symphony_elixir/gitlab_webhook_test.exs` → PASS (all 3).

- [ ] **Step 6: Commit**

```bash
git add lib/symphony_elixir_web/controllers/gitlab_webhook_controller.ex lib/symphony_elixir_web/router.ex test/symphony_elixir/gitlab_webhook_test.exs
git commit -m "feat(review): GitLab webhook controller (X-Gitlab-Token) nudging refresh"
```

---

## Task 7: Full suite, format, docs

- [ ] **Step 1: Full suite** — `export CLOAK_KEY="$(openssl rand -base64 32)"; mix test` → PASS (whole suite green incl. the new tests).
- [ ] **Step 2: Format own files** — `mix format` the files this plan touched, then `mix format --check-formatted <those files>` → clean. Do not reformat unrelated pre-existing files.
- [ ] **Step 3: Docs** — in `docs/roadmap.md`, note under capability (a) that the v1 follow-ups (per-project identity, A3 verification + retry cap, B3 webhook nudges for both forges) are now shipped; the git-truth `files_changed` hardening remains the open follow-up.
- [ ] **Step 4: Commit** — `git add docs/roadmap.md && git commit -m "docs(review): note interactive-review follow-ups shipped"`.

---

## Self-Review notes (for the executor)

- **Spec coverage:** identity callback + resolver (T1, T2 / Phase 1); files_changed contract + resolve guard (T3 / Phase 2 V3); per-thread retry cap + needs-human (T4 / Phase 2); GitHub events (T5), GitLab controller (T6 / Phase 3 W2); suite + roadmap (T7). Out-of-scope (git-truth compare, direct dispatch) stays out.
- **Type consistency:** new names — `Forge.current_user/1`, `Forge.Memory.seed_current_user/1`, `Review.Identity.resolve/3` + `reset_cache/0`, `Storage.review_attempt_count/2` + `increment_review_attempt/2`, handoff `files_changed` parse + `maybe_resolve/6` guard. The normalized `thread` shape (with `path`) and the per-thread `dedupe_key` format are reused unchanged from v1.
- **Verify-before-implement flags (confirm against real code):** the `/user` GET helper idiom + request_fun call convention per client (T1); `:ets` lifecycle under the suite (T2); `mark_dedupe_claimed/1` metadata-merge behavior + `DedupeKey` alias (T4); the per-thread dedupe-key threading from source→run→handoff (T4 NOTE); the GitHub controller's real refresh path to replicate for GitLab (T6); the existing `github_webhook_test.exs` accepted-event assertion to mirror (T5).
- **Fail-fast caveat:** every `mix` command needs `CLOAK_KEY` exported.
```
