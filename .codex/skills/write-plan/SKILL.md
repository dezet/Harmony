---
name: write-plan
description:
  Turn an approved/committed specification into a checkbox implementation plan under
  docs/superpowers/plans; use in the `Plan` state after the spec is written. Port of
  the superpowers writing-plans methodology.
---

# Write Plan

Turn the committed spec from the `Spec` state into a step-by-step implementation plan
that a coding agent can execute task-by-task. This is the autonomous port of the
superpowers `writing-plans` flow, producing a plan in the same format the repository
already uses in `docs/superpowers/plans/`.

## Goals

- Decompose the spec into ordered, independently reviewable tasks with checkboxes.
- Keep each task small enough to implement and verify in isolation; sequence tasks
  so the branch stays shippable (tracer-bullet vertical slices where possible).
- Make every ticket-provided validation requirement an explicit gate in the plan.
- Leave a committed artifact the human approves at the `Plan Approval` gate before
  any implementation begins.

## Preconditions

- The issue is in the `Plan` state.
- A committed spec exists from the `write-spec` skill (its path is linked in the workpad).

## Inputs

- The committed spec document (the single source of intended scope and decisions).
- The repository's plan conventions (`docs/superpowers/plans/`), especially the
  roadmap index `docs/superpowers/plans/2026-05-31-00-roadmap-plan-index.md`.

## Steps

1. Re-read the committed spec end to end. Do not re-derive scope — the spec is fixed
   input; if it is wrong, the issue should go back to `Spec`, not be patched here.
2. Decompose into phases and tasks:
   - Each task is a checkbox `- [ ]` line; group with parent/child structure.
   - Order by dependency; prefer slices that keep `main` shippable after each task.
   - Each task names the files/modules it touches and the test that proves it.
3. Define validation gates explicitly:
   - Per-milestone and global commands (`mix format --check-formatted`,
     `mix specs.check`, `mix test`; `make all` before calling work production-ready).
   - Mirror every ticket-provided `Validation`/`Test Plan`/`Testing` item as a
     required check (no optional downgrade).
   - Add Manual Integration Gates for anything that needs a controlled manual run.
4. Write the plan to the path in **Output** using the **Template**.
5. Self-review: no placeholders; tasks are concrete and individually verifiable;
   the plan covers the whole spec scope and nothing beyond it.
6. Commit the plan with the `commit` skill and publish with the `push` skill.
7. Link the committed plan path in the workpad and note "Spec + Plan ready for human
   approval" with both artifact paths.
8. Transition the issue `Plan` -> `Plan Approval` and end the turn. Do not start
   implementation — `Plan Approval` is the human gate.

## Output

A single Markdown file:

```
docs/superpowers/plans/<YYYY-MM-DD>-<issue-identifier-lower>-<slug>.md
```

Example: `docs/superpowers/plans/2026-06-03-mt-686-project-config-ui.md`.

The first line after the title MUST be the agentic-worker header so executors pick
the right sub-skill:

```md
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.
```

## Handoff / approval gate

The plan is reviewed together with the spec at `Plan Approval`. If the human moves
the issue back to `Plan`, refine the committed plan in place to address their
comments and re-advance through the gate. Implementation only starts once the human
moves the issue to `In Progress`.

## Template

Mirror the structure of existing plans in `docs/superpowers/plans/`. Scale sections
to the work; small tickets may collapse Execution Order into a single phase.

````md
# <Title> Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** <one-line outcome>

**Architecture:** <how the pieces fit; reference the spec>

**Tech Stack:** <relevant stack>

---

## Tasks

- [ ] 1. <Parent task> — files: `<path>`; proof: `<test/command>`
  - [ ] 1.1 <Child task>
- [ ] 2. <Parent task>

## Validation

```bash
cd elixir
mix format --check-formatted
mix specs.check
mix test
```

## Manual Integration Gates

- <Controlled manual runs and what each must record (project slug, repo/PR, work
  run id, validation commands, artifact paths).>
````
