import { describe, it, expect } from "vitest";
import { projectHealth, needsAttention } from "@/lib/health";

describe("projectHealth", () => {
  it("is blocked when anything is blocked", () => {
    expect(projectHealth({ running: 3, retrying: 2, blocked: 1 })).toBe("blocked");
  });
  it("is retrying when retries pend and nothing is blocked", () => {
    expect(projectHealth({ running: 3, retrying: 2, blocked: 0 })).toBe("retrying");
  });
  it("is healthy when only running", () => {
    expect(projectHealth({ running: 3, retrying: 0, blocked: 0 })).toBe("healthy");
  });
  it("is idle when nothing is active", () => {
    expect(projectHealth({ running: 0, retrying: 0, blocked: 0 })).toBe("idle");
  });
});

describe("needsAttention", () => {
  it("collects blocked runs, failing retries, and sandbox warnings", () => {
    const items = needsAttention({
      generated_at: "2026-06-12T00:00:00Z",
      blocked: [
        {
          issue_id: "b1",
          issue_identifier: "HAR-42",
          state: "In Progress",
          error: "sandbox denied",
          worker_host: null,
          workspace_path: null,
          session_id: null,
          blocked_at: "2026-06-12T00:00:00Z",
          last_event: null,
          last_message: null,
          last_event_at: null,
          project: { id: "p1", name: "Alpha", slug: "alpha" },
        },
      ],
      retrying: [
        {
          issue_id: "r1",
          issue_identifier: "HAR-38",
          attempt: 3,
          due_at: null,
          error: "agent timeout",
          worker_host: null,
          workspace_path: null,
          project: null,
        },
        {
          issue_id: "r2",
          issue_identifier: "HAR-39",
          attempt: 1,
          due_at: null,
          error: null,
          worker_host: null,
          workspace_path: null,
          project: null,
        },
      ],
      runtime: {
        sandbox: {
          posture: null,
          bubblewrap_available: null,
          apparmor_restrict_unprivileged_userns: null,
          thread_sandbox: null,
          turn_sandbox_type: null,
          warnings: ["bubblewrap unavailable"],
        },
      },
    });

    expect(items.map((i) => i.kind)).toEqual(["blocked", "retry_error", "sandbox_warning"]);
    expect(items[0].identifier).toBe("HAR-42");
    expect(items[0].projectSlug).toBe("alpha");
    expect(items[1].message).toContain("agent timeout");
    // HAR-39 has no error -> a pending retry is normal operation, not attention-worthy.
    expect(items.find((i) => i.identifier === "HAR-39")).toBeUndefined();
  });

  it("returns an empty list when everything is clear", () => {
    expect(needsAttention({ generated_at: "2026-06-12T00:00:00Z" })).toEqual([]);
  });
});
