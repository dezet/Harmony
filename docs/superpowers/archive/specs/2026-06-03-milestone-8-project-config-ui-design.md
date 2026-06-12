# Milestone 8 Project Configuration UI Design

## Purpose

Milestone 8 originally groups several platform expansion items. In the current repository, the
agent backend interface, Codex adapter extraction, Claude Code and Pi non-interactive adapters,
GitHub webhook receiver, inline review comment module, and video evidence module exist. The
remaining vertical product gap for this slice is a hardened database-backed React project
configuration UI that lets Harmony operate more than one configured project without editing YAML for
routine changes.

This spec scopes the implementation to hardening the existing React project configuration screens
against the existing Phoenix JSON CRUD API. It does not introduce LiveView, deletes, webhooks,
multi-agent execution, or additional runtime scheduling semantics.

## Current Baseline

The Elixir app exposes `/api/v1/projects` endpoints through `SymphonyElixirWeb.ProjectController`.
The controller reads and writes Postgres-backed project records through `SymphonyElixir.Storage`.
The React SPA already has:

- `/projects` list route.
- `/projects/new` create route.
- `/projects/:id/edit` edit route.
- React Query hooks for list, show, create, and update.
- Client-side JSON validation for the config textarea.
- Server validation error mapping from `config` to `config_json`.

The baseline is functional but thin. The list has no empty or error state, the edit screen has no
loading or not-found treatment, saving uses only React Hook Form submission state rather than the
actual mutation pending state, and the tests do not cover edit, not-found, empty list, or failed API
states.

## Goals

- Make the project configuration UI reliable enough for more than one configured Harmony project.
- Keep YAML project sync as an import/bootstrap path, while making database records editable from
  the SPA.
- Preserve the existing Phoenix JSON API and React Router architecture.
- Add focused frontend tests for the behavior that protects operators from silent failed saves or
  confusing empty/edit states.

## Non-Goals

- No project deletion UI.
- No LiveView rewrite.
- No new backend fields beyond the existing project schema.
- No automatic runtime reload or scheduler changes after saving a project.
- No authentication or authorization layer.
- No inline diff review comment UX.

## UX Requirements

The project list must show:

- A loading skeleton while the list query is pending.
- A clear empty state when no projects exist.
- A clear error state when the list request fails.
- A table with slug, GitHub repo, base branch, Linear project slug, config version, and edit link
  when projects exist.

The project form must show:

- A loading skeleton while an edit record is loading.
- A clear not-found/error state when an edit record cannot be loaded.
- Create mode with default `config_version` of `1` and config JSON `{}`.
- Edit mode with the database record hydrated into the form.
- Client-side validation for required slug, GitHub owner, GitHub repo, base branch, positive integer
  config version, and JSON-object config.
- Server-side field errors mapped back onto their form fields, including `config` to `config_json`.
- Save button disabled while the corresponding create or update mutation is pending.
- Successful save navigates back to `/projects`.

## Architecture

The implementation stays in the existing React SPA:

- `ProjectsPage` remains the list route and consumes `useProjects`.
- `ProjectFormPage` remains the create/edit route and consumes `useProject`, `useCreateProject`,
  and `useUpdateProject`.
- `useProjects.ts` remains the React Query boundary over `lib/api.ts`.
- `projectSchema.ts` remains the form validation and `ProjectInput` translation boundary.

No new backend module is required for this slice because the Phoenix project API and storage tests
already cover the database write path. The work is deliberately frontend-focused and uses mocked
`fetch` in Vitest route tests.

## Error Handling

List query failures render an operator-visible message instead of an empty table.

Edit query failures render an operator-visible message and a link back to the project list. A failed
edit fetch must not render a blank create-like form, because that could lead to accidental duplicate
project creation or overwriting the wrong record.

Mutation failures keep the user on the form. Field errors are rendered next to fields and surfaced
through accessible descriptions. Non-field API errors are shown through the existing toast mechanism.

## Testing

Frontend tests must cover:

- Empty project list state.
- Failed project list state.
- Edit form hydration from the API.
- Failed edit load state.
- Update submission using the loaded project id.
- Save button disabled while a create mutation is pending.

Existing backend API tests remain the database contract coverage. Targeted verification should run
the project route tests and frontend typecheck. Full handoff should run the broader frontend suite
when time allows.

## Acceptance Criteria

- Operators can distinguish loading, empty, loaded, and failed project list states.
- Operators can distinguish edit loading, loaded, and failed edit states.
- Create and update saves cannot be double-submitted while a mutation is pending.
- Existing create behavior and server validation mapping continue to pass.
- The implementation is covered by focused Vitest tests.
