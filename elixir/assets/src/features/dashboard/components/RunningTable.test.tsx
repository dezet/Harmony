import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { RunningTable } from "@/features/dashboard/components/RunningTable";
import type { RunningEntry } from "@/types/contract";

const nowMs = new Date("2026-06-02T00:01:00Z").getTime();

const entry: RunningEntry = {
  issue_id: "1",
  issue_identifier: "COD-1",
  state: "running",
  worker_host: "host-a",
  workspace_path: null,
  session_id: "s1",
  turn_count: 3,
  last_event: "codex.message",
  last_message: "working",
  started_at: "2026-06-02T00:00:00Z",
  last_event_at: null,
  tokens: { input_tokens: 1, output_tokens: 2, total_tokens: 3 },
  project: { id: "p", name: "Portal", slug: "portal" },
};

describe("RunningTable", () => {
  it("renders a row with identifier, project, and elapsed time", () => {
    render(<RunningTable rows={[entry]} nowMs={nowMs} />);
    expect(screen.getByText("COD-1")).toBeInTheDocument();
    expect(screen.getByText("Portal")).toBeInTheDocument();
    expect(screen.getByText("1m 0s")).toBeInTheDocument();
  });

  it("renders an empty state when there are no rows", () => {
    render(<RunningTable rows={[]} nowMs={nowMs} />);
    expect(screen.getByText(/no running sessions/i)).toBeInTheDocument();
  });
});
