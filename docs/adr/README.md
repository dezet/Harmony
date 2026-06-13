# Architecture Decision Records

This directory records significant architectural decisions for Harmony — the *why* behind choices
that are expensive to reverse or that a future reader would otherwise have to reverse-engineer.

## Format

One file per decision, numbered sequentially: `NNNN-short-title.md`. Each record has:

- **Status** — Proposed | Accepted | Superseded by ADR-XXXX | Deprecated
- **Context** — the forces at play: constraints, the problem, what the codebase makes easy/hard
- **Decision** — what we chose, stated plainly
- **Consequences** — what becomes easier, what becomes harder, residual risks
- **Alternatives considered** — what we rejected and why

Keep them short. An ADR is a decision, not a design doc — detailed designs live in
`docs/superpowers/specs/`, and task breakdowns in `docs/superpowers/plans/`.

## Index

- [0001](0001-soft-stop-semantics.md) — Operator "stop run" is a soft stop (Accepted)
- [0002](0002-attempt-history-persistence.md) — Persist run attempts in a dedicated table (Proposed, Phase 6)
- [0003](0003-run-transcript-log-capture.md) — Capture the run transcript at the orchestrator, not from disk (Proposed, Phase 6)
