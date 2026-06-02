# Phase 2 — Projects CRUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a JSON REST API for projects (list / show / create / update) and React screens — a projects list and a create/edit form — matching today's LiveView capabilities exactly (no delete).

**Architecture:** A `ProjectController` (with an `action_fallback` to a new `FallbackController`) reuses `Storage.list_projects/0`, `Storage.get_project!/1`, and `Storage.upsert_project/1`. Validation errors render as HTTP 422 with `error.fields`. The React form uses React Hook Form + Yup; on a 422 it maps `error.fields` onto field errors. Project mutations invalidate the `['projects']` React Query cache.

**Tech Stack:** Phoenix controller + JSON, Ecto changeset, ExUnit (`Phoenix.ConnTest`, `@tag :db`); React Query mutations, React Hook Form, Yup, shadcn/ui form primitives.

**Prereq:** Phase 1 complete. The flat project JSON shape matches `src/types/contract.ts` (extended here).

---

## File Structure

Backend:
- Create: `elixir/lib/symphony_elixir_web/controllers/project_controller.ex`
- Create: `elixir/lib/symphony_elixir_web/controllers/fallback_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex` (add project routes BEFORE the `:issue_identifier` catch-all)
- Create: `elixir/test/symphony_elixir/project_api_test.exs`

Frontend (`elixir/assets/src/`):
- Modify: `types/contract.ts` (add `Project`, `ProjectInput`)
- Modify: `lib/api.ts` (project endpoints)
- Create: `features/projects/useProjects.ts` (queries + mutations)
- Modify: `routes/ProjectsPage.tsx`, `routes/ProjectFormPage.tsx`
- Create: `routes/ProjectsPage.test.tsx`, `routes/ProjectFormPage.test.tsx`

---

### Task 1: FallbackController (error envelope)

**Files:**
- Create: `elixir/lib/symphony_elixir_web/controllers/fallback_controller.ex`

- [ ] **Step 1: Implement the fallback controller**

`elixir/lib/symphony_elixir_web/controllers/fallback_controller.ex`:

```elixir
defmodule SymphonyElixirWeb.FallbackController do
  @moduledoc """
  Translates action `{:error, _}` returns into the JSON error envelope
  `%{error: %{code, message, fields?}}`.
  """

  use Phoenix.Controller, formats: [:json]

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "validation_failed",
        message: "Validation failed",
        fields: changeset_errors(changeset)
      }
    })
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "Resource not found"}})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
```

- [ ] **Step 2: Compile check**

```bash
cd /work/Projekty/Harmony/elixir
mix compile
```

Expected: compiles (warnings about unused are fine; no errors).

- [ ] **Step 3: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/lib/symphony_elixir_web/controllers/fallback_controller.ex
git commit -m "feat(web): add JSON fallback controller for error envelope"
```

---

### Task 2: ProjectController + routes

**Files:**
- Create: `elixir/lib/symphony_elixir_web/controllers/project_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Test: `elixir/test/symphony_elixir/project_api_test.exs`

- [ ] **Step 1: Write the failing API test**

`elixir/test/symphony_elixir/project_api_test.exs`:

```elixir
defmodule SymphonyElixir.ProjectApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    start_test_endpoint()
    :ok
  end

  @valid %{
    "slug" => "portal",
    "linear_project_slug" => "portal-linear",
    "linear_team_key" => "COD",
    "linear_human_review_state" => "Human Review",
    "github_owner" => "dezet",
    "github_repo" => "portal",
    "github_base_branch" => "main",
    "config_version" => 1,
    "config" => %{"review" => %{"trigger" => "@hreview"}}
  }

  defp json_post(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp json_put(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put(path, Jason.encode!(body))
  end

  @tag :db
  test "creates a project and lists it" do
    :ok = checkout_repo(%{})

    conn = json_post("/api/v1/projects", @valid)
    assert %{"project" => %{"id" => id, "slug" => "portal", "github_repo" => "portal"}} =
             json_response(conn, 201)
    assert is_binary(id)

    list = get(build_conn(), "/api/v1/projects")
    assert %{"projects" => [%{"slug" => "portal"}]} = json_response(list, 200)
  end

  @tag :db
  test "returns 422 with field errors for an invalid project" do
    :ok = checkout_repo(%{})

    conn = json_post("/api/v1/projects", Map.delete(@valid, "slug"))
    body = json_response(conn, 422)
    assert body["error"]["code"] == "validation_failed"
    assert is_list(body["error"]["fields"]["slug"])
  end

  @tag :db
  test "updates an existing project" do
    :ok = checkout_repo(%{})
    {:ok, project} = SymphonyElixir.Storage.upsert_project(atomize(@valid))

    conn = json_put("/api/v1/projects/#{project.id}", Map.put(@valid, "github_base_branch", "develop"))
    assert %{"project" => %{"github_base_branch" => "develop"}} = json_response(conn, 200)
  end

  @tag :db
  test "returns 404 for an unknown project id" do
    :ok = checkout_repo(%{})
    conn = get(build_conn(), "/api/v1/projects/00000000-0000-0000-0000-000000000000")
    assert json_response(conn, 404)["error"]["code"] == "not_found"
  end

  defp atomize(map), do: Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)

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

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /work/Projekty/Harmony/elixir
mix test test/symphony_elixir/project_api_test.exs
```

Expected: FAIL — routes/controller missing (likely the GET list is captured by the `:issue_identifier` route returning 404 issue_not_found, and POST has no route).

- [ ] **Step 3: Implement the controller**

`elixir/lib/symphony_elixir_web/controllers/project_controller.ex`:

```elixir
defmodule SymphonyElixirWeb.ProjectController do
  @moduledoc """
  JSON CRUD for projects (list / show / create / update). Mirrors the LiveView
  project form. No delete by design.
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.Storage

  action_fallback(SymphonyElixirWeb.FallbackController)

  @permitted ~w(slug linear_project_slug linear_team_key linear_human_review_state
                github_owner github_repo github_base_branch config_version config)

  def index(conn, _params) do
    json(conn, %{projects: Enum.map(Storage.list_projects(), &project_json/1)})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, project} <- fetch_project(id) do
      json(conn, %{project: project_json(project)})
    end
  end

  def create(conn, params) do
    with {:ok, project} <- Storage.upsert_project(project_attrs(params)) do
      conn |> put_status(:created) |> json(%{project: project_json(project)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, _existing} <- fetch_project(id),
         {:ok, project} <- Storage.upsert_project(project_attrs(params)) do
      json(conn, %{project: project_json(project)})
    end
  end

  defp fetch_project(id) do
    {:ok, Storage.get_project!(id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp project_attrs(params), do: Map.take(params, @permitted)

  defp project_json(p) do
    %{
      id: p.id,
      slug: p.slug,
      linear_project_slug: p.linear_project_slug,
      linear_team_key: p.linear_team_key,
      linear_human_review_state: p.linear_human_review_state,
      github_owner: p.github_owner,
      github_repo: p.github_repo,
      github_base_branch: p.github_base_branch,
      config_version: p.config_version,
      config: p.config,
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end
end
```

- [ ] **Step 4: Add routes (BEFORE the `:issue_identifier` catch-all)**

In `elixir/lib/symphony_elixir_web/router.ex`, inside the API scope, insert these lines IMMEDIATELY BEFORE `get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)`:

```elixir
    get("/api/v1/projects", ProjectController, :index)
    post("/api/v1/projects", ProjectController, :create)
    get("/api/v1/projects/:id", ProjectController, :show)
    put("/api/v1/projects/:id", ProjectController, :update)
    patch("/api/v1/projects/:id", ProjectController, :update)
```

> Order matters: `GET /api/v1/projects` is a single segment and would otherwise be captured by `get("/api/v1/:issue_identifier", ...)`. It MUST be declared first.

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /work/Projekty/Harmony/elixir
mix test test/symphony_elixir/project_api_test.exs
```

Expected: 4 passing tests. (If the list test 404s, the route order in Step 4 is wrong.)

- [ ] **Step 6: Format, full test, commit**

```bash
cd /work/Projekty/Harmony/elixir
mix format
mix test
cd /work/Projekty/Harmony
git add elixir/lib/symphony_elixir_web/controllers/project_controller.ex elixir/lib/symphony_elixir_web/router.ex elixir/test/symphony_elixir/project_api_test.exs
git commit -m "feat(web): add project CRUD JSON API"
```

---

### Task 3: Project types + API client functions

**Files:**
- Modify: `elixir/assets/src/types/contract.ts`
- Modify: `elixir/assets/src/lib/api.ts`

- [ ] **Step 1: Add project types to `contract.ts`**

Append to `elixir/assets/src/types/contract.ts`:

```ts
export interface Project {
  id: string;
  slug: string;
  linear_project_slug: string | null;
  linear_team_key: string | null;
  linear_human_review_state: string | null;
  github_owner: string;
  github_repo: string;
  github_base_branch: string;
  config_version: number;
  config: Record<string, unknown>;
  inserted_at: string;
  updated_at: string;
}

// What the form submits. `config` is an object (parsed from the JSON textarea).
export interface ProjectInput {
  slug: string;
  linear_project_slug?: string | null;
  linear_team_key?: string | null;
  linear_human_review_state?: string | null;
  github_owner: string;
  github_repo: string;
  github_base_branch: string;
  config_version: number;
  config: Record<string, unknown>;
}
```

- [ ] **Step 2: Add project endpoints to `api.ts`**

Append to `elixir/assets/src/lib/api.ts` (the `request` helper and `ApiError` are already defined there):

```ts
import type { Project, ProjectInput } from "@/types/contract";

export function getProjects(): Promise<Project[]> {
  return request<{ projects: Project[] }>("/projects").then((r) => r.projects);
}

export function getProject(id: string): Promise<Project> {
  return request<{ project: Project }>(`/projects/${id}`).then((r) => r.project);
}

export function createProject(input: ProjectInput): Promise<Project> {
  return request<{ project: Project }>("/projects", {
    method: "POST",
    body: JSON.stringify(input),
  }).then((r) => r.project);
}

export function updateProject(id: string, input: ProjectInput): Promise<Project> {
  return request<{ project: Project }>(`/projects/${id}`, {
    method: "PUT",
    body: JSON.stringify(input),
  }).then((r) => r.project);
}
```

> Move the new `import type { Project, ProjectInput }` to the top of the file alongside the existing type import (`import type { ApiErrorBody, StatePayload, Project, ProjectInput } from "@/types/contract";`).

- [ ] **Step 3: Build to verify types**

```bash
cd /work/Projekty/Harmony/elixir/assets
npm run build
```

Expected: exits 0.

- [ ] **Step 4: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/types/contract.ts elixir/assets/src/lib/api.ts
git commit -m "feat(frontend): add project types and REST client functions"
```

---

### Task 4: React Query hooks for projects

**Files:**
- Create: `elixir/assets/src/features/projects/useProjects.ts`

- [ ] **Step 1: Implement the hooks**

`elixir/assets/src/features/projects/useProjects.ts`:

```ts
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createProject, getProject, getProjects, updateProject } from "@/lib/api";
import type { Project, ProjectInput } from "@/types/contract";

const PROJECTS_KEY = ["projects"] as const;

export function useProjects() {
  return useQuery<Project[]>({ queryKey: PROJECTS_KEY, queryFn: getProjects });
}

export function useProject(id: string | undefined) {
  return useQuery<Project>({
    queryKey: ["project", id],
    queryFn: () => getProject(id as string),
    enabled: !!id,
  });
}

export function useCreateProject() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: ProjectInput) => createProject(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: PROJECTS_KEY }),
  });
}

export function useUpdateProject(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: ProjectInput) => updateProject(id, input),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: PROJECTS_KEY });
      qc.invalidateQueries({ queryKey: ["project", id] });
    },
  });
}
```

- [ ] **Step 2: Build, commit**

```bash
cd /work/Projekty/Harmony/elixir/assets
npm run build
cd /work/Projekty/Harmony
git add elixir/assets/src/features/projects/useProjects.ts
git commit -m "feat(frontend): add project React Query hooks and mutations"
```

---

### Task 5: Projects list screen

**Files:**
- Modify: `elixir/assets/src/routes/ProjectsPage.tsx`
- Create: `elixir/assets/src/routes/ProjectsPage.test.tsx`

- [ ] **Step 1: Write the failing test**

`elixir/assets/src/routes/ProjectsPage.test.tsx`:

```tsx
import { render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter } from "react-router-dom";
import { describe, it, expect, vi, afterEach } from "vitest";
import { ProjectsPage } from "@/routes/ProjectsPage";

afterEach(() => vi.restoreAllMocks());

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <ProjectsPage />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("ProjectsPage", () => {
  it("lists projects from the API", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(
          JSON.stringify({ projects: [{ id: "1", slug: "portal", github_owner: "dezet", github_repo: "portal", github_base_branch: "main", linear_team_key: "COD", linear_project_slug: "p", linear_human_review_state: "Human Review", config_version: 2, config: {}, inserted_at: "", updated_at: "" }] }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
      ),
    );

    renderPage();
    await waitFor(() => expect(screen.getByText("portal")).toBeInTheDocument());
    expect(screen.getByText("dezet/portal")).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
npm run test -- --run src/routes/ProjectsPage.test.tsx
```

Expected: FAIL — current `ProjectsPage` is the placeholder.

- [ ] **Step 3: Implement the list screen**

`elixir/assets/src/routes/ProjectsPage.tsx`:

```tsx
import { Link } from "react-router-dom";
import { useProjects } from "@/features/projects/useProjects";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";

export function ProjectsPage() {
  const { data, isLoading } = useProjects();

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">Projects</h1>
        <Button asChild>
          <Link to="/projects/new">New project</Link>
        </Button>
      </div>

      {isLoading ? (
        <Skeleton className="h-24 w-full" />
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Slug</TableHead>
              <TableHead>GitHub</TableHead>
              <TableHead>Base branch</TableHead>
              <TableHead>Linear</TableHead>
              <TableHead>Version</TableHead>
              <TableHead></TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(data ?? []).map((p) => (
              <TableRow key={p.id}>
                <TableCell>{p.slug}</TableCell>
                <TableCell>{`${p.github_owner}/${p.github_repo}`}</TableCell>
                <TableCell>{p.github_base_branch}</TableCell>
                <TableCell>{p.linear_project_slug ?? "—"}</TableCell>
                <TableCell>{p.config_version}</TableCell>
                <TableCell>
                  <Link className="underline" to={`/projects/${p.id}/edit`}>
                    Edit
                  </Link>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
npm run test -- --run src/routes/ProjectsPage.test.tsx
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/routes/ProjectsPage.tsx elixir/assets/src/routes/ProjectsPage.test.tsx
git commit -m "feat(frontend): projects list screen"
```

---

### Task 6: Project form (create/edit) with RHF + Yup

**Files:**
- Modify: `elixir/assets/src/routes/ProjectFormPage.tsx`
- Create: `elixir/assets/src/features/projects/projectSchema.ts`
- Create: `elixir/assets/src/routes/ProjectFormPage.test.tsx`
- Add shadcn `form`, `input`, `textarea`, `label`, `sonner` (toast) primitives.

- [ ] **Step 1: Add shadcn primitives**

```bash
cd /work/Projekty/Harmony/elixir/assets
npx shadcn@latest add form input textarea label sonner
```

Expected: creates `src/components/ui/{form,input,textarea,label,sonner}.tsx`.

- [ ] **Step 1b: Mount the toaster in `AppProviders`**

Add the sonner `Toaster` to `elixir/assets/src/providers/AppProviders.tsx` so toast errors render app-wide. Add the import and place `<Toaster />` next to the children:

```tsx
import { Toaster } from "@/components/ui/sonner";
// ...inside AppProviders, within <ErrorBoundary>:
//   <QueryClientProvider client={queryClient}>
//     <ChannelBridge>{children}</ChannelBridge>
//     <Toaster />
//   </QueryClientProvider>
```

- [ ] **Step 2: Create the Yup schema (with JSON config validation)**

`elixir/assets/src/features/projects/projectSchema.ts`:

```ts
import * as yup from "yup";
import type { ProjectInput } from "@/types/contract";

// The form holds `config` as a JSON string in a textarea. This schema validates
// the string parses to a JSON object, and transforms it to the object the API wants.
export const projectFormSchema = yup.object({
  slug: yup.string().trim().required("Slug is required"),
  github_owner: yup.string().trim().required("GitHub owner is required"),
  github_repo: yup.string().trim().required("GitHub repo is required"),
  github_base_branch: yup.string().trim().required("Base branch is required"),
  linear_project_slug: yup.string().trim().nullable().default(""),
  linear_team_key: yup.string().trim().nullable().default(""),
  linear_human_review_state: yup.string().trim().nullable().default(""),
  config_version: yup.number().typeError("Version must be a number").integer().min(1).required(),
  config_json: yup
    .string()
    .default("{}")
    .test("is-json-object", "Config must be a JSON object", (value) => {
      try {
        const parsed = JSON.parse(value || "{}");
        return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed);
      } catch {
        return false;
      }
    }),
});

export type ProjectFormValues = yup.InferType<typeof projectFormSchema>;

export function toProjectInput(values: ProjectFormValues): ProjectInput {
  return {
    slug: values.slug,
    github_owner: values.github_owner,
    github_repo: values.github_repo,
    github_base_branch: values.github_base_branch,
    linear_project_slug: values.linear_project_slug || null,
    linear_team_key: values.linear_team_key || null,
    linear_human_review_state: values.linear_human_review_state || null,
    config_version: values.config_version,
    config: JSON.parse(values.config_json || "{}"),
  };
}
```

- [ ] **Step 3: Write a failing form test (validation + submit + server-error mapping)**

`elixir/assets/src/routes/ProjectFormPage.test.tsx`:

```tsx
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Routes, Route } from "react-router-dom";
import { describe, it, expect, vi, afterEach } from "vitest";
import { ProjectFormPage } from "@/routes/ProjectFormPage";

afterEach(() => vi.restoreAllMocks());

function renderForm() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={["/projects/new"]}>
        <Routes>
          <Route path="/projects/new" element={<ProjectFormPage />} />
          <Route path="/projects" element={<div>Projects list</div>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("ProjectFormPage (create)", () => {
  it("shows a validation error when slug is empty", async () => {
    renderForm();
    await userEvent.click(screen.getByRole("button", { name: /save/i }));
    expect(await screen.findByText(/slug is required/i)).toBeInTheDocument();
  });

  it("submits and navigates to the list on success", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ project: { id: "1" } }), {
          status: 201,
          headers: { "content-type": "application/json" },
        }),
      ),
    );

    renderForm();
    await userEvent.type(screen.getByLabelText(/slug/i), "portal");
    await userEvent.type(screen.getByLabelText(/owner/i), "dezet");
    await userEvent.type(screen.getByLabelText(/repo/i), "portal");
    await userEvent.type(screen.getByLabelText(/base branch/i), "main");
    await userEvent.click(screen.getByRole("button", { name: /save/i }));

    await waitFor(() => expect(screen.getByText("Projects list")).toBeInTheDocument());
  });
});
```

- [ ] **Step 4: Run it to verify it fails**

```bash
npm run test -- --run src/routes/ProjectFormPage.test.tsx
```

Expected: FAIL — current `ProjectFormPage` is the placeholder.

- [ ] **Step 5: Implement the form screen**

`elixir/assets/src/routes/ProjectFormPage.tsx`:

```tsx
import { useEffect } from "react";
import { useForm } from "react-hook-form";
import { yupResolver } from "@hookform/resolvers/yup";
import { useNavigate, useParams } from "react-router-dom";
import { projectFormSchema, toProjectInput, type ProjectFormValues } from "@/features/projects/projectSchema";
import { useCreateProject, useProject, useUpdateProject } from "@/features/projects/useProjects";
import { ApiError } from "@/lib/api";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";

const FIELDS = [
  { name: "slug", label: "Slug" },
  { name: "github_owner", label: "GitHub owner" },
  { name: "github_repo", label: "GitHub repo" },
  { name: "github_base_branch", label: "Base branch" },
  { name: "linear_project_slug", label: "Linear project slug" },
  { name: "linear_team_key", label: "Linear team key" },
  { name: "linear_human_review_state", label: "Linear human review state" },
] as const;

export function ProjectFormPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const editing = !!id;
  const { data: project } = useProject(id);
  const createMut = useCreateProject();
  const updateMut = useUpdateProject(id ?? "");

  const {
    register,
    handleSubmit,
    reset,
    setError,
    formState: { errors, isSubmitting },
  } = useForm<ProjectFormValues>({
    resolver: yupResolver(projectFormSchema),
    defaultValues: { config_version: 1, config_json: "{}" },
  });

  useEffect(() => {
    if (project) {
      reset({
        slug: project.slug,
        github_owner: project.github_owner,
        github_repo: project.github_repo,
        github_base_branch: project.github_base_branch,
        linear_project_slug: project.linear_project_slug ?? "",
        linear_team_key: project.linear_team_key ?? "",
        linear_human_review_state: project.linear_human_review_state ?? "",
        config_version: project.config_version,
        config_json: JSON.stringify(project.config ?? {}, null, 2),
      });
    }
  }, [project, reset]);

  async function onSubmit(values: ProjectFormValues) {
    const input = toProjectInput(values);
    try {
      if (editing) {
        await updateMut.mutateAsync(input);
      } else {
        await createMut.mutateAsync(input);
      }
      navigate("/projects");
    } catch (err) {
      if (err instanceof ApiError && err.fields) {
        for (const [field, messages] of Object.entries(err.fields)) {
          setError(field as keyof ProjectFormValues, { message: messages.join(", ") });
        }
      } else if (err instanceof ApiError) {
        toast.error(err.message);
      } else {
        toast.error("Unexpected error saving the project");
      }
    }
  }

  return (
    <form className="max-w-xl space-y-4" onSubmit={handleSubmit(onSubmit)}>
      <h1 className="text-2xl font-semibold">{editing ? "Edit project" : "New project"}</h1>

      {FIELDS.map((f) => (
        <div key={f.name} className="space-y-1">
          <Label htmlFor={f.name}>{f.label}</Label>
          <Input id={f.name} {...register(f.name)} />
          {errors[f.name] ? <p className="text-sm text-destructive">{errors[f.name]?.message}</p> : null}
        </div>
      ))}

      <div className="space-y-1">
        <Label htmlFor="config_version">Config version</Label>
        <Input id="config_version" type="number" {...register("config_version")} />
        {errors.config_version ? <p className="text-sm text-destructive">{errors.config_version.message}</p> : null}
      </div>

      <div className="space-y-1">
        <Label htmlFor="config_json">Config (JSON)</Label>
        <Textarea id="config_json" rows={8} {...register("config_json")} />
        {errors.config_json ? <p className="text-sm text-destructive">{errors.config_json.message}</p> : null}
      </div>

      <Button type="submit" disabled={isSubmitting}>
        Save
      </Button>
    </form>
  );
}
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
npm run test -- --run src/routes/ProjectFormPage.test.tsx
```

Expected: PASS. (The `getByLabelText(/owner/i)` matches "GitHub owner"; `/repo/i` matches "GitHub repo".)

- [ ] **Step 7: Commit**

```bash
cd /work/Projekty/Harmony
git add elixir/assets/src/routes/ProjectFormPage.tsx elixir/assets/src/features/projects/projectSchema.ts elixir/assets/src/routes/ProjectFormPage.test.tsx elixir/assets/src/components/ui
git commit -m "feat(frontend): project create/edit form with RHF + Yup"
```

---

## Phase 2 Final Validation

- [ ] From `elixir/`: `mix format --check-formatted && mix test` exit 0 (project API test included).
- [ ] From `elixir/assets/`: `npm run lint && npm run test -- --run && npm run build` exit 0.
- [ ] **Manual gate:** with the app running, open `/app/projects`, create a project via `/app/projects/new`, confirm it appears in the list and in `GET /api/v1/projects`; edit it via the edit link and confirm the change persists.
- [ ] `/` and `/projects` (LiveView) still work unchanged.
