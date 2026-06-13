# Project Picker (Phase 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace free-text repo/tracker slugs in the Configuration form with searchable pickers backed by stateless, token-in-body read endpoints, auto-filling owner/repo/default-branch and Linear project/team from live API data.

**Architecture:** New `Tracker.list_projects/1` (Linear GraphQL teams→projects, token override) mirrors the existing `Forge.list_repositories/2`. Two stateless `POST` endpoints (`/api/v1/forge/repositories`, `/api/v1/tracker/projects`) take `{token, …}` from the request body (env fallback), dispatch via `Forge.adapter/1` / `Tracker.adapter/0`, cap at 200, and return normalized lists. The React form gains a `forge_type` select + `forge_base_url` input and two comboboxes that lazily fetch on open and auto-fill the underlying fields.

**Tech Stack:** Elixir, Phoenix, Ecto, ExUnit; React 19 + Vite + React Query + React Hook Form + Yup, Vitest + RTL.

**Spec:** `docs/superpowers/specs/2026-06-13-project-picker-design.md`

**Test DB / key:** Backend tests need Postgres (podman `harmony-postgres` on 5432) and `CLOAK_KEY` (Phase 2 fail-fast). Export before any `mix` command, from `elixir/`:

```
export CLOAK_KEY="$(openssl rand -base64 32)"
```

Frontend commands run from `elixir/assets/`.

---

## File Structure

**Backend**
- Modify `elixir/lib/symphony_elixir/tracker.ex` — add `list_projects/1` callback + delegate.
- Modify `elixir/lib/symphony_elixir/tracker/memory.ex` — `list_projects/1` (canned, app-env seeded).
- Modify `elixir/lib/symphony_elixir/linear/adapter.ex` — `list_projects/1` delegate to client.
- Modify `elixir/lib/symphony_elixir/linear/client.ex` — `list_projects/2` (GraphQL) + `:token` override in `graphql/3`/`graphql_headers/1`.
- Modify `elixir/lib/symphony_elixir/forge.ex` — `adapter/1` recognizes `"memory"` (test seam).
- Create `elixir/lib/symphony_elixir_web/controllers/forge_picker_controller.ex`.
- Create `elixir/lib/symphony_elixir_web/controllers/tracker_picker_controller.ex`.
- Modify `elixir/lib/symphony_elixir_web/router.ex` — two routes.

**Frontend**
- Create `elixir/assets/src/components/Combobox.tsx` — searchable select (custom, no cmdk dep).
- Modify `elixir/assets/src/types/contract.ts` — `ForgeRepository`, `TrackerProject`, `Project`/`ProjectInput` (`forge_type`, `forge_base_url`).
- Modify `elixir/assets/src/lib/api.ts` — `listForgeRepositories`, `listTrackerProjects`.
- Create `elixir/assets/src/features/projects/usePickers.ts` — React Query lazy mutations.
- Modify `elixir/assets/src/features/projects/projectSchema.ts` — `forge_type`, `forge_base_url`.
- Modify `elixir/assets/src/features/project/components/ProjectConfigForm.tsx` — selects + comboboxes.

---

## Task 1: `Tracker.list_projects/1` behaviour + Memory adapter

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker.ex`
- Modify: `elixir/lib/symphony_elixir/tracker/memory.ex`
- Test: `elixir/test/symphony_elixir/tracker_list_projects_test.exs`

- [ ] **Step 1: Write the failing test**

Create `elixir/test/symphony_elixir/tracker_list_projects_test.exs`:

```elixir
defmodule SymphonyElixir.TrackerListProjectsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Tracker

  setup do
    prev = Application.get_env(:symphony_elixir, :memory_tracker_projects)
    on_exit(fn -> Application.put_env(:symphony_elixir, :memory_tracker_projects, prev) end)
    :ok
  end

  test "list_projects/1 returns the memory adapter's seeded projects" do
    Application.put_env(:symphony_elixir, :memory_tracker_projects, [
      %{id: "p1", name: "Portal", slug: "portal", team_key: "COD"}
    ])

    assert {:ok, [%{id: "p1", name: "Portal", slug: "portal", team_key: "COD"}]} =
             Tracker.list_projects(%{token: "ignored-by-memory"})
  end
end
```

(The test relies on `config/config.exs` setting `tracker.kind` to `"memory"` in `:test`; verify it does — existing tracker tests depend on the same.)

- [ ] **Step 2: Run it (fails)**

Run: `mix test test/symphony_elixir/tracker_list_projects_test.exs`
Expected: FAIL — `function SymphonyElixir.Tracker.list_projects/1 is undefined`.

- [ ] **Step 3: Add the callback + delegate**

In `elixir/lib/symphony_elixir/tracker.ex`, add the callback after the existing `@callback` lines:

```elixir
  @callback list_projects(creds :: map()) :: {:ok, [map()]} | {:error, term()}
```

And the delegate after `update_issue_state/2`:

```elixir
  @spec list_projects(map()) :: {:ok, [map()]} | {:error, term()}
  def list_projects(creds) when is_map(creds) do
    adapter().list_projects(creds)
  end
```

- [ ] **Step 4: Implement the Memory adapter callback**

In `elixir/lib/symphony_elixir/tracker/memory.ex`, add:

```elixir
  @spec list_projects(map()) :: {:ok, [map()]}
  def list_projects(_creds) do
    {:ok, Application.get_env(:symphony_elixir, :memory_tracker_projects, [])}
  end
```

- [ ] **Step 5: Run it (passes)**

Run: `mix test test/symphony_elixir/tracker_list_projects_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/symphony_elixir/tracker.ex lib/symphony_elixir/tracker/memory.ex test/symphony_elixir/tracker_list_projects_test.exs
git commit -m "feat(picker): Tracker.list_projects behaviour + memory adapter"
```

---

## Task 2: Linear `list_projects` (GraphQL) with token override

**Files:**
- Modify: `elixir/lib/symphony_elixir/linear/client.ex`
- Modify: `elixir/lib/symphony_elixir/linear/adapter.ex`
- Test: `elixir/test/symphony_elixir/linear_list_projects_test.exs`

- [ ] **Step 1: Write the failing test**

Create `elixir/test/symphony_elixir/linear_list_projects_test.exs`:

```elixir
defmodule SymphonyElixir.LinearListProjectsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Client

  @body %{
    "data" => %{
      "teams" => %{
        "nodes" => [
          %{
            "key" => "COD",
            "projects" => %{
              "nodes" => [
                %{"id" => "p1", "name" => "Portal", "slugId" => "portal"},
                %{"id" => "p2", "name" => "Mobile", "slugId" => "mobile"}
              ]
            }
          }
        ]
      }
    }
  }

  test "list_projects/2 normalizes teams->projects and passes the creds token" do
    test_pid = self()

    request_fun = fn _payload, headers ->
      send(test_pid, {:headers, headers})
      {:ok, %{status: 200, body: @body}}
    end

    assert {:ok, projects} = Client.list_projects(%{token: "tok-123"}, request_fun: request_fun)

    assert projects == [
             %{id: "p1", name: "Portal", slug: "portal", team_key: "COD"},
             %{id: "p2", name: "Mobile", slug: "mobile", team_key: "COD"}
           ]

    assert_received {:headers, headers}
    assert {"Authorization", "tok-123"} in headers
  end
end
```

- [ ] **Step 2: Run it (fails)**

Run: `mix test test/symphony_elixir/linear_list_projects_test.exs`
Expected: FAIL — `function SymphonyElixir.Linear.Client.list_projects/2 is undefined`.

- [ ] **Step 3: Add the `:token` override to `graphql/3` + `graphql_headers/1`**

In `elixir/lib/symphony_elixir/linear/client.ex`, change `graphql/3` to thread an optional token. Replace the `with {:ok, headers} <- graphql_headers(),` line inside `graphql/3` with:

```elixir
    with {:ok, headers} <- graphql_headers(Keyword.get(opts, :token)),
```

Replace the `defp graphql_headers do` head with an arity-1 version (default `nil` keeps existing callers working):

```elixir
  defp graphql_headers(override_token \\ nil) do
    case override_token || Config.settings!().tracker.api_key do
```

(The body — `nil -> {:error, :missing_linear_api_token}` / `token -> {:ok, [...]}` — is unchanged.)

- [ ] **Step 4: Add `list_projects/2` + normalizer**

In `elixir/lib/symphony_elixir/linear/client.ex`, add a module attribute near the other `@query` definitions:

```elixir
  @list_projects_query """
  query SymphonyListProjects {
    teams {
      nodes {
        key
        projects(first: 250) {
          nodes { id name slugId }
        }
      }
    }
  }
  """
```

And the public function + normalizer (place near `graphql/3`):

```elixir
  @spec list_projects(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_projects(creds, opts \\ []) when is_map(creds) do
    opts = Keyword.put_new(opts, :token, Map.get(creds, :token))

    with {:ok, body} <- graphql(@list_projects_query, %{}, opts) do
      {:ok, normalize_projects(body)}
    end
  end

  defp normalize_projects(body) do
    body
    |> get_in(["data", "teams", "nodes"])
    |> List.wrap()
    |> Enum.flat_map(fn team ->
      team
      |> get_in(["projects", "nodes"])
      |> List.wrap()
      |> Enum.map(fn p ->
        %{id: p["id"], name: p["name"], slug: p["slugId"], team_key: team["key"]}
      end)
    end)
  end
```

> Slug mapping (spec risk): this uses Linear's `slugId` as `linear_project_slug`. If the configured value the orchestrator polls with is the project *name* or URL slug instead, adjust `normalize_projects/1` and the GraphQL field together. The test fixture above pins the current mapping.

- [ ] **Step 5: Add the adapter delegate**

In `elixir/lib/symphony_elixir/linear/adapter.ex`, add:

```elixir
  @spec list_projects(map()) :: {:ok, [map()]} | {:error, term()}
  def list_projects(creds), do: Client.list_projects(creds)
```

- [ ] **Step 6: Run it (passes)**

Run: `mix test test/symphony_elixir/linear_list_projects_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/symphony_elixir/linear/client.ex lib/symphony_elixir/linear/adapter.ex test/symphony_elixir/linear_list_projects_test.exs
git commit -m "feat(picker): Linear list_projects via GraphQL with token override"
```

---

## Task 3: `Forge.adapter/1` memory dispatch (test seam)

**Files:**
- Modify: `elixir/lib/symphony_elixir/forge.ex`
- Test: `elixir/test/symphony_elixir/forge_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `elixir/test/symphony_elixir/forge_test.exs`, inside the module (it already aliases `Forge`):

```elixir
  test "adapter/1 dispatches forge_type \"memory\" to the Memory adapter" do
    assert Forge.adapter(%{forge_type: "memory"}) == SymphonyElixir.Forge.Memory
  end
```

- [ ] **Step 2: Run it (fails)**

Run: `mix test test/symphony_elixir/forge_test.exs -k "memory"`
Expected: FAIL — returns `SymphonyElixir.Forge.Github`, not `Memory`.

- [ ] **Step 3: Implement**

In `elixir/lib/symphony_elixir/forge.ex`, change `adapter/1`:

```elixir
  def adapter(project) do
    case Map.get(project, :forge_type) || "github" do
      "gitlab" -> SymphonyElixir.Forge.Gitlab
      "memory" -> SymphonyElixir.Forge.Memory
      _ -> SymphonyElixir.Forge.Github
    end
  end
```

- [ ] **Step 4: Run it (passes)**

Run: `mix test test/symphony_elixir/forge_test.exs`
Expected: PASS (existing dispatch tests + the new one).

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/forge.ex test/symphony_elixir/forge_test.exs
git commit -m "feat(picker): Forge.adapter recognizes memory forge_type for tests"
```

---

## Task 4: Forge picker endpoint + controller

**Files:**
- Create: `elixir/lib/symphony_elixir_web/controllers/forge_picker_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Test: `elixir/test/symphony_elixir/forge_picker_api_test.exs`

- [ ] **Step 1: Write the failing test**

Create `elixir/test/symphony_elixir/forge_picker_api_test.exs`:

```elixir
defmodule SymphonyElixir.ForgePickerApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    start_test_endpoint()
    Forge.Memory.reset()
    :ok
  end

  alias SymphonyElixir.Forge

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  test "lists repositories for a forge with a token" do
    Forge.Memory.seed_repositories([
      %{owner: "dezet", name: "portal", default_branch: "main", url: "https://x/portal"}
    ])

    conn = post_json("/api/v1/forge/repositories", %{forge_type: "memory", token: "tok"})

    assert %{"repositories" => [repo], "truncated" => false} = json_response(conn, 200)
    assert repo == %{"owner" => "dezet", "name" => "portal", "default_branch" => "main", "url" => "https://x/portal"}
  end

  test "422 when no token and no env fallback" do
    System.delete_env("GITHUB_TOKEN")
    System.delete_env("GH_TOKEN")

    conn = post_json("/api/v1/forge/repositories", %{forge_type: "github", token: ""})

    assert json_response(conn, 422)["error"]["code"] == "missing_credentials"
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
```

> Note: `Forge.Memory.list_repositories/2` ignores `creds`, so the `"memory"` dispatch needs no request stub. For `"github"`/`"gitlab"` the controller passes `creds.request_fun` (nil in prod → real HTTP); the memory path is what the controller tests exercise.

- [ ] **Step 2: Run it (fails)**

Run: `mix test test/symphony_elixir/forge_picker_api_test.exs`
Expected: FAIL — no route / controller.

- [ ] **Step 3: Create the controller**

Create `elixir/lib/symphony_elixir_web/controllers/forge_picker_controller.ex`:

```elixir
defmodule SymphonyElixirWeb.ForgePickerController do
  @moduledoc """
  Stateless repository picker: lists a forge's repositories using a token from
  the request body (global-env fallback), for the Configuration form pickers.
  The token is never persisted or echoed.
  """
  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Forge

  @cap 200

  @spec repositories(Conn.t(), map()) :: Conn.t()
  def repositories(conn, params) do
    forge_type = params["forge_type"] || "github"
    token = blank_to_nil(params["token"]) || env_token(forge_type)
    base_url = blank_to_nil(params["base_url"])

    cond do
      is_nil(token) ->
        error(conn, 422, "missing_credentials")

      true ->
        creds = %{token: token, base_url: base_url, request_fun: nil}

        case Forge.adapter(%{forge_type: forge_type}).list_repositories(creds, []) do
          {:ok, repos} ->
            capped = Enum.take(repos, @cap)

            json(conn, %{
              repositories: Enum.map(capped, &repo_json/1),
              truncated: length(repos) > @cap
            })

          {:error, reason} ->
            map_error(conn, reason, "forge")
        end
    end
  end

  defp repo_json(r) do
    %{owner: r[:owner], name: r[:name], default_branch: r[:default_branch], url: r[:url]}
  end

  defp env_token("gitlab"), do: System.get_env("GITLAB_TOKEN")
  defp env_token(_), do: System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)

  defp map_error(conn, reason, prefix) do
    case auth_status?(reason) do
      true -> error(conn, 422, "#{prefix}_auth_failed")
      false -> error(conn, 502, "#{prefix}_unreachable")
    end
  end

  # Adapter errors carry the upstream status in a tuple, e.g. {:github_api_status, 401}.
  defp auth_status?(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&(&1 in [401, 403]))
  rescue
    _ -> false
  end

  defp error(conn, status, code) do
    conn |> put_status(status) |> json(%{error: %{code: code}})
  end
end
```

- [ ] **Step 4: Add the route**

In `elixir/lib/symphony_elixir_web/router.ex`, add inside the API `scope "/", SymphonyElixirWeb do` block, near the other `/api/v1/projects` routes (and before the catch-all `get("/api/v1/:issue_identifier", ...)`):

```elixir
    post("/api/v1/forge/repositories", ForgePickerController, :repositories)
```

- [ ] **Step 5: Run it (passes)**

Run: `mix test test/symphony_elixir/forge_picker_api_test.exs`
Expected: PASS (both tests).

- [ ] **Step 6: Commit**

```bash
git add lib/symphony_elixir_web/controllers/forge_picker_controller.ex lib/symphony_elixir_web/router.ex test/symphony_elixir/forge_picker_api_test.exs
git commit -m "feat(picker): POST /api/v1/forge/repositories endpoint"
```

---

## Task 5: Tracker picker endpoint + controller

**Files:**
- Create: `elixir/lib/symphony_elixir_web/controllers/tracker_picker_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Test: `elixir/test/symphony_elixir/tracker_picker_api_test.exs`

- [ ] **Step 1: Write the failing test**

Create `elixir/test/symphony_elixir/tracker_picker_api_test.exs`:

```elixir
defmodule SymphonyElixir.TrackerPickerApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    start_test_endpoint()
    prev = Application.get_env(:symphony_elixir, :memory_tracker_projects)
    on_exit(fn -> Application.put_env(:symphony_elixir, :memory_tracker_projects, prev) end)
    :ok
  end

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  test "lists tracker projects for a token" do
    Application.put_env(:symphony_elixir, :memory_tracker_projects, [
      %{id: "p1", name: "Portal", slug: "portal", team_key: "COD"}
    ])

    conn = post_json("/api/v1/tracker/projects", %{token: "tok"})

    assert %{"projects" => [proj], "truncated" => false} = json_response(conn, 200)
    assert proj == %{"id" => "p1", "name" => "Portal", "slug" => "portal", "team_key" => "COD"}
  end

  test "422 when no token and no env fallback" do
    System.delete_env("LINEAR_API_KEY")
    conn = post_json("/api/v1/tracker/projects", %{token: ""})
    assert json_response(conn, 422)["error"]["code"] == "missing_credentials"
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
```

- [ ] **Step 2: Run it (fails)**

Run: `mix test test/symphony_elixir/tracker_picker_api_test.exs`
Expected: FAIL — no route / controller.

- [ ] **Step 3: Create the controller**

Create `elixir/lib/symphony_elixir_web/controllers/tracker_picker_controller.ex`:

```elixir
defmodule SymphonyElixirWeb.TrackerPickerController do
  @moduledoc """
  Stateless tracker-project picker: lists Linear projects using a token from the
  request body (global-env fallback). The token is never persisted or echoed.
  """
  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Tracker

  @cap 200

  @spec projects(Conn.t(), map()) :: Conn.t()
  def projects(conn, params) do
    token = blank_to_nil(params["token"]) || System.get_env("LINEAR_API_KEY")

    cond do
      is_nil(token) ->
        error(conn, 422, "missing_credentials")

      true ->
        case Tracker.list_projects(%{token: token}) do
          {:ok, projects} ->
            capped = Enum.take(projects, @cap)

            json(conn, %{
              projects: Enum.map(capped, &project_json/1),
              truncated: length(projects) > @cap
            })

          {:error, reason} ->
            map_error(conn, reason)
        end
    end
  end

  defp project_json(p) do
    %{id: p[:id], name: p[:name], slug: p[:slug], team_key: p[:team_key]}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)

  defp map_error(conn, reason) do
    if auth_status?(reason) do
      error(conn, 422, "tracker_auth_failed")
    else
      error(conn, 502, "tracker_unreachable")
    end
  end

  defp auth_status?(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&(&1 in [401, 403]))
  rescue
    _ -> false
  end

  defp error(conn, status, code) do
    conn |> put_status(status) |> json(%{error: %{code: code}})
  end
end
```

- [ ] **Step 4: Add the route**

In `elixir/lib/symphony_elixir_web/router.ex`, add next to the forge picker route:

```elixir
    post("/api/v1/tracker/projects", TrackerPickerController, :projects)
```

- [ ] **Step 5: Run it (passes)**

Run: `mix test test/symphony_elixir/tracker_picker_api_test.exs`
Expected: PASS (both tests).

- [ ] **Step 6: Commit**

```bash
git add lib/symphony_elixir_web/controllers/tracker_picker_controller.ex lib/symphony_elixir_web/router.ex test/symphony_elixir/tracker_picker_api_test.exs
git commit -m "feat(picker): POST /api/v1/tracker/projects endpoint"
```

---

## Task 6: Contract types + API functions + hooks

**Files:**
- Modify: `elixir/assets/src/types/contract.ts`
- Modify: `elixir/assets/src/lib/api.ts`
- Create: `elixir/assets/src/features/projects/usePickers.ts`

- [ ] **Step 1: Add contract types**

In `elixir/assets/src/types/contract.ts`, add near `ProjectInput`:

```typescript
export interface ForgeRepository {
  owner: string;
  name: string;
  default_branch: string;
  url: string;
}

export interface ForgeRepositoriesResponse {
  repositories: ForgeRepository[];
  truncated: boolean;
}

export interface TrackerProject {
  id: string;
  name: string;
  slug: string;
  team_key: string;
}

export interface TrackerProjectsResponse {
  projects: TrackerProject[];
  truncated: boolean;
}

export interface ForgeRepositoriesRequest {
  forge_type: string;
  base_url?: string | null;
  token?: string | null;
}

export interface TrackerProjectsRequest {
  token?: string | null;
  base_url?: string | null;
}
```

Add `forge_type` and `forge_base_url` to `Project` (after `github_base_branch`):

```typescript
  forge_type: string;
  forge_base_url: string | null;
```

And to `ProjectInput` (after `github_base_branch`):

```typescript
  forge_type?: string;
  forge_base_url?: string | null;
```

- [ ] **Step 2: Add the controller's `forge_type`/`forge_base_url` to `project_json`**

The form needs these back from `GET /api/v1/projects/:id`. In `elixir/lib/symphony_elixir_web/controllers/project_controller.ex`, inside `project_json/1`, add after `github_base_branch: p.forge_base_branch,`:

```elixir
      forge_type: p.forge_type,
      forge_base_url: p.forge_base_url,
```

Run: `export CLOAK_KEY="$(openssl rand -base64 32)"; mix test test/symphony_elixir/project_api_test.exs`
Expected: PASS (existing project API tests still green with the extra keys — they use partial matches).

- [ ] **Step 3: Add API client functions**

In `elixir/assets/src/lib/api.ts`, add (mirroring the existing `request<T>` helper and `createProject` shape):

```typescript
export function listForgeRepositories(
  body: ForgeRepositoriesRequest,
): Promise<ForgeRepositoriesResponse> {
  return request<ForgeRepositoriesResponse>("/forge/repositories", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

export function listTrackerProjects(
  body: TrackerProjectsRequest,
): Promise<TrackerProjectsResponse> {
  return request<TrackerProjectsResponse>("/tracker/projects", {
    method: "POST",
    body: JSON.stringify(body),
  });
}
```

Add the new types to the existing `import type { … } from "@/types/contract";` block at the top of `api.ts`: `ForgeRepositoriesRequest`, `ForgeRepositoriesResponse`, `TrackerProjectsRequest`, `TrackerProjectsResponse`.

- [ ] **Step 4: Add lazy hooks**

Create `elixir/assets/src/features/projects/usePickers.ts`:

```typescript
import { useMutation } from "@tanstack/react-query";
import { listForgeRepositories, listTrackerProjects } from "@/lib/api";
import type {
  ForgeRepositoriesRequest,
  ForgeRepositoriesResponse,
  TrackerProjectsRequest,
  TrackerProjectsResponse,
} from "@/types/contract";

// Lazy: triggered when a picker opens, not on mount.
export function useForgeRepositories() {
  return useMutation<ForgeRepositoriesResponse, Error, ForgeRepositoriesRequest>({
    mutationFn: (body) => listForgeRepositories(body),
  });
}

export function useTrackerProjects() {
  return useMutation<TrackerProjectsResponse, Error, TrackerProjectsRequest>({
    mutationFn: (body) => listTrackerProjects(body),
  });
}
```

- [ ] **Step 5: Typecheck**

Run (from `elixir/assets`): `npm run typecheck`
Expected: passes (no usage yet beyond definitions; the form wiring is Task 8).

- [ ] **Step 6: Commit**

```bash
git add elixir/assets/src/types/contract.ts elixir/assets/src/lib/api.ts elixir/assets/src/features/projects/usePickers.ts elixir/lib/symphony_elixir_web/controllers/project_controller.ex
git commit -m "feat(picker): contract types, api fns, lazy hooks; expose forge_type/base_url"
```

---

## Task 7: Combobox component

**Files:**
- Create: `elixir/assets/src/components/Combobox.tsx`
- Test: `elixir/assets/src/components/Combobox.test.tsx`

A focused searchable select on existing primitives (avoids the cmdk/Base-UI dependency for this bounded need; `src/components/ui/*` is CLI-generated and untouched).

- [ ] **Step 1: Write the failing test**

Create `elixir/assets/src/components/Combobox.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, it, expect, vi } from "vitest";
import { Combobox } from "@/components/Combobox";

const items = [
  { value: "a", label: "Alpha" },
  { value: "b", label: "Beta" },
];

describe("Combobox", () => {
  it("calls onOpen the first time it is opened", async () => {
    const onOpen = vi.fn();
    render(<Combobox items={items} value={null} onSelect={() => {}} onOpen={onOpen} label="Repo" />);
    await userEvent.click(screen.getByRole("button", { name: /repo/i }));
    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it("filters by query and selects an item", async () => {
    const onSelect = vi.fn();
    render(<Combobox items={items} value={null} onSelect={onSelect} onOpen={() => {}} label="Repo" />);
    await userEvent.click(screen.getByRole("button", { name: /repo/i }));
    await userEvent.type(screen.getByRole("textbox"), "bet");
    expect(screen.queryByRole("option", { name: "Alpha" })).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("option", { name: "Beta" }));
    expect(onSelect).toHaveBeenCalledWith({ value: "b", label: "Beta" });
  });

  it("shows the current value as the button label", () => {
    render(
      <Combobox items={items} value={{ value: "a", label: "Alpha" }} onSelect={() => {}} onOpen={() => {}} label="Repo" />,
    );
    expect(screen.getByRole("button", { name: /alpha/i })).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run it (fails)**

Run: `npm run test -- --run src/components/Combobox.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the component**

Create `elixir/assets/src/components/Combobox.tsx`:

```tsx
import { useState } from "react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";

export interface ComboboxItem {
  value: string;
  label: string;
}

interface ComboboxProps {
  items: ComboboxItem[];
  value: ComboboxItem | null;
  onSelect: (item: ComboboxItem) => void;
  onOpen: () => void;
  label: string;
  loading?: boolean;
  error?: string | null;
  disabled?: boolean;
}

export function Combobox({
  items,
  value,
  onSelect,
  onOpen,
  label,
  loading,
  error,
  disabled,
}: ComboboxProps) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [openedOnce, setOpenedOnce] = useState(false);

  function toggle() {
    const next = !open;
    setOpen(next);
    if (next && !openedOnce) {
      setOpenedOnce(true);
      onOpen();
    }
  }

  const filtered = items.filter((i) =>
    i.label.toLowerCase().includes(query.trim().toLowerCase()),
  );

  return (
    <div className="relative">
      <Button type="button" variant="outline" onClick={toggle} disabled={disabled} aria-label={label}>
        {value ? value.label : label}
      </Button>
      {open ? (
        <div role="listbox" className="absolute z-10 mt-1 w-full rounded-md border bg-popover p-1 shadow-md">
          <Input
            autoFocus
            value={query}
            placeholder="Search…"
            onChange={(e) => setQuery(e.target.value)}
            aria-label={`${label} search`}
          />
          {loading ? <p className="p-2 text-sm text-muted-foreground">Loading…</p> : null}
          {error ? <p className="p-2 text-sm text-destructive">{error}</p> : null}
          {!loading && !error
            ? filtered.map((item) => (
                <button
                  key={item.value}
                  type="button"
                  role="option"
                  aria-selected={value?.value === item.value}
                  className="block w-full rounded px-2 py-1 text-left text-sm hover:bg-accent"
                  onClick={() => {
                    onSelect(item);
                    setOpen(false);
                    setQuery("");
                  }}
                >
                  {item.label}
                </button>
              ))
            : null}
        </div>
      ) : null}
    </div>
  );
}
```

- [ ] **Step 4: Run it (passes)**

Run: `npm run test -- --run src/components/Combobox.test.tsx`
Expected: PASS (all 3).

- [ ] **Step 5: Commit**

```bash
git add elixir/assets/src/components/Combobox.tsx elixir/assets/src/components/Combobox.test.tsx
git commit -m "feat(picker): searchable Combobox component"
```

---

## Task 8: Wire pickers into the Configuration form

**Files:**
- Modify: `elixir/assets/src/features/projects/projectSchema.ts`
- Modify: `elixir/assets/src/features/project/components/ProjectConfigForm.tsx`
- Modify: `elixir/assets/src/features/project/components/ProjectConfigForm.test.tsx`

- [ ] **Step 1: Add `forge_type`/`forge_base_url` to the schema**

In `elixir/assets/src/features/projects/projectSchema.ts`, add to `projectFormSchema` (after `github_base_branch`):

```typescript
  forge_type: yup.string().trim().default("github"),
  forge_base_url: yup.string().trim().default(""),
```

In `toProjectInput`, add to the returned object (after `github_base_branch`):

```typescript
    forge_type: values.forge_type || "github",
    forge_base_url: values.forge_base_url || null,
```

- [ ] **Step 2: Write the failing form test**

Append to `elixir/assets/src/features/project/components/ProjectConfigForm.test.tsx`, inside the `describe("ProjectConfigForm (edit mode)")` block. First add the new fields to `sampleProject` (after `github_base_branch`):

```tsx
  forge_type: "github",
  forge_base_url: null,
```

Then the test:

```tsx
  it("opens the repo picker, fetches, and auto-fills owner/repo/branch on select", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = input.toString();
      if (url.endsWith("/api/v1/forge/repositories")) {
        return new Response(
          JSON.stringify({
            repositories: [{ owner: "acme", name: "api", default_branch: "trunk", url: "u" }],
            truncated: false,
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }
      void init;
      return new Response(JSON.stringify({ project: sampleProject }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    vi.stubGlobal("fetch", fetchMock);

    renderForm({ project: sampleProject });
    await waitFor(() => expect(screen.getByLabelText("Slug")).toHaveValue("portal"));

    await userEvent.click(screen.getByRole("button", { name: /repository/i }));
    await screen.findByRole("option", { name: /acme\/api/i });
    await userEvent.click(screen.getByRole("option", { name: /acme\/api/i }));

    expect(screen.getByLabelText("GitHub owner")).toHaveValue("acme");
    expect(screen.getByLabelText("GitHub repo")).toHaveValue("api");
    expect(screen.getByLabelText("Base branch")).toHaveValue("trunk");
  });
```

> The owner/repo/branch fields remain rendered as (read-only-from-picker) inputs so their values are assertable and submitted; the picker writes them via `setValue`.

- [ ] **Step 3: Run it (fails)**

Run: `npm run test -- --run src/features/project/components/ProjectConfigForm.test.tsx`
Expected: FAIL — no "Repository" picker button.

- [ ] **Step 4: Wire the form**

In `elixir/assets/src/features/project/components/ProjectConfigForm.tsx`:

Add imports:

```tsx
import { Combobox, type ComboboxItem } from "@/components/Combobox";
import { useForgeRepositories, useTrackerProjects } from "@/features/projects/usePickers";
```

Pull `setValue` and `watch` from `useForm` (extend the existing destructure):

```tsx
    setValue,
    watch,
```

Add hook instances and watched values inside the component body (after `const updateMut = …`):

```tsx
  const repos = useForgeRepositories();
  const projects = useTrackerProjects();
  const forgeType = watch("forge_type") ?? "github";
  const forgeBaseUrl = watch("forge_base_url") ?? "";
  const forgeToken = watch("forge_secret") ?? "";
  const trackerToken = watch("tracker_secret") ?? "";
  const owner = watch("github_owner");
  const repo = watch("github_repo");
  const linearSlug = watch("linear_project_slug");
```

Add `forge_type`/`forge_base_url` to the `reset(...)` call in the `useEffect` (after `github_base_branch`):

```tsx
        forge_type: project.forge_type ?? "github",
        forge_base_url: project.forge_base_url ?? "",
```

Replace the rendered free-text triplet (the `FIELDS.map` covers slug/owner/repo/branch/linear today) by **removing** `github_owner`, `github_repo`, `github_base_branch`, `linear_project_slug`, `linear_team_key` from the `FIELDS` array so only non-picker fields stay:

```tsx
const FIELDS = [
  { name: "slug", label: "Slug" },
  { name: "linear_human_review_state", label: "Linear human review state" },
] as const;
```

Then add the forge controls + pickers just before the `config_version` block:

```tsx
      <div className="space-y-1">
        <Label htmlFor="forge_type">Forge</Label>
        <select id="forge_type" className="block w-full rounded-md border p-2" {...register("forge_type")}>
          <option value="github">GitHub</option>
          <option value="gitlab">GitLab</option>
        </select>
      </div>

      <div className="space-y-1">
        <Label htmlFor="forge_base_url">Forge base URL (self-host, optional)</Label>
        <Input id="forge_base_url" {...register("forge_base_url")} />
      </div>

      <div className="space-y-1">
        <Label>Repository</Label>
        <Combobox
          label="Repository"
          value={owner && repo ? { value: `${owner}/${repo}`, label: `${owner}/${repo}` } : null}
          items={(repos.data?.repositories ?? []).map((r) => ({
            value: `${r.owner}/${r.name}`,
            label: `${r.owner}/${r.name}`,
          }))}
          loading={repos.isPending}
          error={repos.isError ? "Could not list repositories — check the token and retry." : null}
          onOpen={() =>
            repos.mutate({ forge_type: forgeType, base_url: forgeBaseUrl || null, token: forgeToken || null })
          }
          onSelect={(item: ComboboxItem) => {
            const r = (repos.data?.repositories ?? []).find((x) => `${x.owner}/${x.name}` === item.value);
            if (r) {
              setValue("github_owner", r.owner, { shouldDirty: true });
              setValue("github_repo", r.name, { shouldDirty: true });
              setValue("github_base_branch", r.default_branch, { shouldDirty: true });
            }
          }}
        />
        <Input aria-label="GitHub owner" {...register("github_owner")} readOnly />
        <Input aria-label="GitHub repo" {...register("github_repo")} readOnly />
        <Input aria-label="Base branch" {...register("github_base_branch")} readOnly />
      </div>

      <div className="space-y-1">
        <Label>Linear project</Label>
        <Combobox
          label="Linear project"
          value={linearSlug ? { value: linearSlug, label: linearSlug } : null}
          items={(projects.data?.projects ?? []).map((p) => ({
            value: p.slug,
            label: `${p.name} (${p.team_key})`,
          }))}
          loading={projects.isPending}
          error={projects.isError ? "Could not list projects — check the token and retry." : null}
          onOpen={() => projects.mutate({ token: trackerToken || null, base_url: null })}
          onSelect={(item: ComboboxItem) => {
            const p = (projects.data?.projects ?? []).find((x) => x.slug === item.value);
            if (p) {
              setValue("linear_project_slug", p.slug, { shouldDirty: true });
              setValue("linear_team_key", p.team_key, { shouldDirty: true });
            }
          }}
        />
      </div>
```

> The owner/repo/branch `<Input>`s are kept (read-only) so their values render, submit, and are assertable; the picker writes them via `setValue`. Per spec Decision 3 there is no free-text editing path.

- [ ] **Step 5: Run it (passes)**

Run: `npm run test -- --run src/features/project/components/ProjectConfigForm.test.tsx`
Expected: PASS (existing form tests + the new picker test).

- [ ] **Step 6: Typecheck + full FE suite**

Run (from `elixir/assets`): `npm run typecheck && npm run test -- --run`
Expected: typecheck clean; all suites pass. (If `contract.test.ts` asserts exact `Project` keys via a fixture, add `forge_type`/`forge_base_url` there to match — mirror the Phase 2 pattern.)

- [ ] **Step 7: Commit**

```bash
git add elixir/assets/src/features/projects/projectSchema.ts elixir/assets/src/features/project/components/ProjectConfigForm.tsx elixir/assets/src/features/project/components/ProjectConfigForm.test.tsx
git commit -m "feat(picker): repo + Linear project pickers in the configuration form"
```

---

## Task 9: Build + full green

- [ ] **Step 1: Build assets**

Run (from `elixir/assets`): `npm run build`
Expected: build succeeds.

- [ ] **Step 2: Full frontend suite**

Run (from `elixir/assets`): `npm run typecheck && npm run test -- --run`
Expected: typecheck clean; all tests pass.

- [ ] **Step 3: Full backend suite**

Run (from `elixir/`, `CLOAK_KEY` exported, `harmony-postgres` up): `mix test`
Expected: PASS — entire suite green including the new picker tests.

- [ ] **Step 4: Format check**

Run (from `elixir/`): `mix format --check-formatted`
Expected: clean (run `mix format` if not).

- [ ] **Step 5: Commit any formatting**

```bash
git add -A
git commit -m "chore(picker): format" --allow-empty
```

---

## Self-Review notes (for the executor)

- **Spec coverage:** `Tracker.list_projects` (T1–T2, spec §1); stateless endpoints (T4–T5, §2); `Forge.adapter` memory seam for tests (T3); controllers + error codes (T4–T5, §3); `forge_type`/`forge_base_url` + comboboxes + auto-fill, picker-only (T6–T8, §4, Decision 3/4); lazy hooks + cap 200 + `truncated` (T4–T6, §5, Decision 2); token-in-body + env fallback (T4–T5, Decision 1).
- **Type consistency:** backend normalized shapes `%{owner,name,default_branch,url}` and `%{id,name,slug,team_key}` match the controllers' `repo_json`/`project_json` and the TS `ForgeRepository`/`TrackerProject`. `list_projects/1` (Tracker), `list_projects/2` (Client/adapter), `Forge.adapter/1`, `useForgeRepositories`/`useTrackerProjects`, `Combobox`/`ComboboxItem` are used exactly as defined.
- **Known risk carried from spec:** Linear `slugId`→`linear_project_slug` mapping is pinned by the T2 fixture; if the orchestrator polls by a different field, adjust `normalize_projects/1` + the GraphQL query together.
- **Fail-fast caveat:** every `mix` command needs `CLOAK_KEY` exported (Phase 2).
```
