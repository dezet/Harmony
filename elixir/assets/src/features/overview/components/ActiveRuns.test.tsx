import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { ActiveRuns } from "@/features/overview/components/ActiveRuns";

describe("ActiveRuns", () => {
  it("renders a row per running session", () => {
    render(
      <ActiveRuns
        rows={[
          {
            issue_id: "i1",
            issue_identifier: "HAR-44",
            state: "In Progress",
            worker_host: null,
            workspace_path: null,
            session_id: "s1",
            turn_count: 7,
            last_event: "turn_completed",
            last_message: null,
            started_at: "2026-06-12T00:00:00Z",
            last_event_at: null,
            tokens: { input_tokens: 1200, output_tokens: 800, total_tokens: 2000 },
            project: { id: "p1", name: "Alpha", slug: "alpha" },
          },
        ]}
      />,
    );
    expect(screen.getByText("HAR-44")).toBeInTheDocument();
    expect(screen.getByText("alpha")).toBeInTheDocument();
    expect(screen.getByText("7")).toBeInTheDocument();
    expect(screen.getByText("2,000")).toBeInTheDocument();
    expect(screen.getByText("turn_completed")).toBeInTheDocument();
  });

  it("renders an empty message without rows", () => {
    render(<ActiveRuns rows={[]} />);
    expect(screen.getByText(/no runs in progress/i)).toBeInTheDocument();
  });
});
