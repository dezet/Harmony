import type { ProjectCounts, StatePayload } from "@/types/contract";

export type ProjectHealth = "healthy" | "retrying" | "blocked" | "idle";

export function projectHealth(counts: ProjectCounts): ProjectHealth {
  if (counts.blocked > 0) return "blocked";
  if (counts.retrying > 0) return "retrying";
  if (counts.running > 0) return "healthy";
  return "idle";
}

export interface AttentionItem {
  key: string;
  kind: "blocked" | "retry_error" | "sandbox_warning";
  identifier: string | null;
  projectSlug: string | null;
  message: string;
  since: string | null;
}

// Spec: Overview "Needs attention" = blocked runs, retries carrying errors,
// sandbox warnings. Order: blocked first (most urgent), then retries, then runtime.
export function needsAttention(state: StatePayload): AttentionItem[] {
  const items: AttentionItem[] = [];

  for (const b of state.blocked ?? []) {
    items.push({
      key: `blocked-${b.issue_id}`,
      kind: "blocked",
      identifier: b.issue_identifier,
      projectSlug: b.project?.slug ?? null,
      message: b.error ?? b.last_message ?? "Blocked",
      since: b.blocked_at,
    });
  }

  for (const r of state.retrying ?? []) {
    if (!r.error) continue;
    items.push({
      key: `retry-${r.issue_id}`,
      kind: "retry_error",
      identifier: r.issue_identifier,
      projectSlug: r.project?.slug ?? null,
      message: `Retry #${r.attempt}: ${r.error}`,
      since: r.due_at,
    });
  }

  for (const warning of state.runtime?.sandbox?.warnings ?? []) {
    items.push({
      key: `sandbox-${warning}`,
      kind: "sandbox_warning",
      identifier: null,
      projectSlug: null,
      message: warning,
      since: null,
    });
  }

  return items;
}
