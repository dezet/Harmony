---
name: write-spec
description:
  Derive and write a design/specification document for a Linear ticket from its
  description, validation sections, and codebase exploration; use in the `Spec`
  state before any planning or implementation. Unattended port of the superpowers
  brainstorming methodology.
---

# Write Spec

Turn a ticket into a committed specification before any plan or code exists. This
is the autonomous equivalent of the superpowers `brainstorming` flow: instead of
interviewing a human one question at a time, you derive purpose, constraints, and
success criteria from the ticket and the existing code, then write the design down
for human review at the `Plan Approval` gate.

## Goals

- Produce one clear, self-consistent specification for the ticket's scope.
- Ground the spec in how the codebase actually works (reuse existing patterns;
  do not invent parallel mechanisms).
- Lock the decisions a plan will depend on, and call out non-goals (YAGNI).
- Leave a committed artifact the human can approve, not an inline comment.

## Preconditions

- The issue is in the `Spec` state and a `## Codex Workpad` comment exists.
- The repository copy is synced with `origin/main` (run the `pull` skill first).

## Inputs

- The ticket title and description.
- Any ticket-authored `Validation`, `Test Plan`, or `Testing` section — these are
  non-negotiable acceptance input and MUST be reflected in the spec's Testing section.
- Exploration of existing code: modules, conventions, and patterns the work touches.

## Steps

1. Explore project context: read the relevant code, docs, and recent commits for
   the area the ticket touches. Identify existing functions/utilities/patterns to
   reuse instead of proposing new code.
2. Scope check: if the ticket describes multiple independent subsystems, record in
   the workpad that it should be decomposed, and spec only the first coherent
   sub-project. Do not spec an over-large surface in one document.
3. Derive the essentials from the inputs (no human Q&A):
   - Purpose: the problem and intended outcome.
   - Constraints: technical, compatibility, and the trusted-env posture.
   - Success criteria: what "done" means, including the ticket's validation items.
4. Consider 2–3 approaches internally; pick a recommended one and record the
   trade-off and rationale in the spec's Locked Decisions section.
5. Write the design document to the path in **Output** using the **Template**
   structure. Break the system into small units with clear, testable boundaries.
6. Spec self-review (fix inline, no second pass needed):
   - Placeholder scan: no `TBD`, `TODO`, or vague requirements remain.
   - Internal consistency: sections do not contradict; architecture matches features.
   - Scope: focused enough for a single implementation plan.
   - Ambiguity: any requirement open to two readings is made explicit (pick one).
7. Commit the spec with the `commit` skill and publish with the `push` skill.
8. Link the committed spec path in the workpad (do not paste the full spec in the
   comment). Update the workpad `Notes` with a one-line summary of the chosen approach.
9. Transition the issue `Spec` -> `Plan` and continue into the planning flow
   (`.codex/skills/write-plan/SKILL.md`) in the same turn.

## Output

A single Markdown file:

```
docs/superpowers/specs/<YYYY-MM-DD>-<issue-identifier-lower>-<slug>-design.md
```

- `<YYYY-MM-DD>`: today's date.
- `<issue-identifier-lower>`: the Linear identifier, lowercased (e.g. `mt-686`).
- `<slug>`: short kebab-case topic slug.

Example: `docs/superpowers/specs/2026-06-03-mt-686-project-config-ui-design.md`.

## Handoff / approval gate

The interactive "user approves the design" step from superpowers brainstorming is
replaced by the Linear `Plan Approval` gate. Do not ask the human inline. The spec
is reviewed together with the plan after Step 1b; if the human moves the issue back
to `Spec`, refine the committed spec in place to address their comments.

## Template

Mirror the structure of existing specs in `docs/superpowers/specs/`
(e.g. `2026-06-02-react-websockets-frontend-design.md`). Scale each section to its
complexity; omit a section only when it genuinely does not apply.

````md
# <Title>

## Purpose

<Why this change exists: the problem and the intended outcome.>

## Current Baseline

<How the relevant part of the system works today, with concrete module/file references.>

## Goals

- <Outcome-level goals.>

## Non-Goals (YAGNI)

- <Explicitly excluded scope, with a one-line reason.>

## Locked Decisions

<Decisions the plan depends on, with the rejected alternatives and rationale.>

## Target Architecture

<Components, data flow, interfaces. Keep units small and independently testable.>

## Testing

<How the change is validated. MUST include every ticket-provided Validation/Test
Plan/Testing requirement as a concrete check.>

## Risks / Watch-items

- <Known risks and things to verify during implementation.>
````
