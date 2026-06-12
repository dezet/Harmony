# Milestone 8 Project Configuration UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the database-backed React project configuration UI so milestone 8 can operate multiple persisted Harmony project configs without YAML-only edits.

**Architecture:** Keep the existing Phoenix JSON project API and React SPA. Add UX states and tests in the React route components, leaving backend storage and scheduler semantics unchanged.

**Tech Stack:** React 19, React Router 7, TanStack Query 5, React Hook Form, Yup, Vitest, Testing Library, Phoenix JSON API.

---

## File Structure

- Modify: `elixir/assets/src/routes/ProjectsPage.tsx`
  - Responsibility: render loading, empty, error, and loaded states for the project list.
- Modify: `elixir/assets/src/routes/ProjectFormPage.tsx`
  - Responsibility: render create/edit form states, hydrate edit data, block duplicate saves while mutations are pending, and preserve field error mapping.
- Modify: `elixir/assets/src/routes/ProjectsPage.test.tsx`
  - Responsibility: route-level tests for list loaded, empty, and failed states.
- Modify: `elixir/assets/src/routes/ProjectFormPage.test.tsx`
  - Responsibility: route-level tests for create, edit hydration, failed edit load, update submission, field errors, and pending save state.

## Tasks

### Task 1: Cover Project List Empty And Error States

**Files:**
- Modify: `elixir/assets/src/routes/ProjectsPage.test.tsx`
- Modify: `elixir/assets/src/routes/ProjectsPage.tsx`

- [ ] **Step 1: Write failing tests**

Add tests that mock `GET /api/v1/projects` returning `[]` and `500`, then assert the empty and error states.

```tsx
it("shows an empty state when no projects exist", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(
      async () =>
        new Response(JSON.stringify({ projects: [] }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    ),
  );

  renderPage();

  expect(await screen.findByText("No projects configured")).toBeInTheDocument();
  expect(screen.getByRole("link", { name: /new project/i })).toHaveAttribute(
    "href",
    "/projects/new",
  );
});

it("shows an error state when projects cannot be loaded", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(
      async () =>
        new Response(JSON.stringify({ error: { code: "db_down", message: "Database unavailable" } }), {
          status: 500,
          headers: { "content-type": "application/json" },
        }),
    ),
  );

  renderPage();

  expect(await screen.findByText("Could not load projects")).toBeInTheDocument();
  expect(screen.getByText("Database unavailable")).toBeInTheDocument();
});
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cd elixir/assets
npm test -- ProjectsPage.test.tsx --run
```

Expected: the new tests fail because `ProjectsPage` renders an empty table for empty data and has no error branch.

- [ ] **Step 3: Implement list states**

Update `ProjectsPage` to read `error` and `isError` from `useProjects`, render an empty state when `(data ?? []).length === 0`, and render the API error message when available.

```tsx
const { data, isLoading, isError, error } = useProjects();
const projects = data ?? [];

if (isError) {
  const message = error instanceof Error ? error.message : "Unexpected error";
  return (
    <div className="space-y-4">
      <ProjectListHeader />
      <div role="alert" className="rounded-md border border-destructive/40 p-4">
        <h2 className="font-medium">Could not load projects</h2>
        <p className="text-sm text-muted-foreground">{message}</p>
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
cd elixir/assets
npm test -- ProjectsPage.test.tsx --run
```

Expected: all `ProjectsPage` tests pass.

### Task 2: Cover Edit Loading, Not Found, And Update Submit

**Files:**
- Modify: `elixir/assets/src/routes/ProjectFormPage.test.tsx`
- Modify: `elixir/assets/src/routes/ProjectFormPage.tsx`

- [ ] **Step 1: Write failing edit tests**

Add an edit renderer and tests for hydration, failed load, and update payload.

```tsx
function renderEditForm(id = "project-1") {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });

  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={[`/projects/${id}/edit`]}>
        <Routes>
          <Route path="/projects/:id/edit" element={<ProjectFormPage />} />
          <Route path="/projects" element={<div>Projects list</div>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

it("hydrates the edit form from the loaded project", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            project: {
              id: "project-1",
              slug: "portal",
              github_owner: "dezet",
              github_repo: "portal",
              github_base_branch: "develop",
              linear_project_slug: "portal-linear",
              linear_team_key: "COD",
              linear_human_review_state: "Human Review",
              config_version: 3,
              config: { review: { trigger: "@hreview" } },
              inserted_at: "",
              updated_at: "",
            },
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
    ),
  );

  renderEditForm();

  expect(await screen.findByDisplayValue("portal")).toBeInTheDocument();
  expect(screen.getByDisplayValue("develop")).toBeInTheDocument();
  expect(screen.getByLabelText("Config (JSON)")).toHaveValue(
    JSON.stringify({ review: { trigger: "@hreview" } }, null, 2),
  );
});
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cd elixir/assets
npm test -- ProjectFormPage.test.tsx --run
```

Expected: failed-load and pending-state tests fail until explicit UI branches are implemented.

- [ ] **Step 3: Implement edit states**

In `ProjectFormPage`, derive:

```tsx
const projectQuery = useProject(id);
const { data: project, isLoading: isProjectLoading, isError: isProjectError, error: projectError } =
  projectQuery;
const isSaving = createMut.isPending || updateMut.isPending;
```

Render a skeleton while `editing && isProjectLoading`; render an alert and back link while
`editing && isProjectError`; disable save with `isSaving`.

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
cd elixir/assets
npm test -- ProjectFormPage.test.tsx --run
```

Expected: all project form tests pass.

### Task 3: Run Focused Verification

**Files:**
- Verify: `elixir/assets/src/routes/ProjectsPage.test.tsx`
- Verify: `elixir/assets/src/routes/ProjectFormPage.test.tsx`
- Verify: `elixir/assets/src/types/contract.ts`

- [ ] **Step 1: Run route tests**

Run:

```bash
cd elixir/assets
npm test -- ProjectsPage.test.tsx ProjectFormPage.test.tsx --run
```

Expected: both route test files pass.

- [ ] **Step 2: Run frontend typecheck**

Run:

```bash
cd elixir/assets
npm run typecheck
```

Expected: TypeScript completes without errors.

- [ ] **Step 3: Run backend project API tests**

Run:

```bash
cd elixir
mix test test/symphony_elixir/project_api_test.exs
```

Expected: Phoenix project CRUD contract still passes.

## Self-Review

- Spec coverage: The tasks cover list empty/error states, edit loading/error states, edit hydration,
  update submission, mutation pending disable, and focused verification.
- Placeholder scan: No placeholders or unresolved follow-up markers remain in this plan.
- Type consistency: The plan uses existing `Project`, `ProjectInput`, `ProjectFormValues`, and
  React Query mutation names already present in the codebase.
