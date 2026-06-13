import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, it, expect } from "vitest";
import { ActiveRuns } from "@/features/overview/components/ActiveRuns";

describe("ActiveRuns", () => {
  it("renders a row per running session", () => {
    render(
      <MemoryRouter>
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
        />
      </MemoryRouter>,
    );
    expect(screen.getByText("HAR-44")).toBeInTheDocument();
    expect(screen.getByText("alpha")).toBeInTheDocument();
    expect(screen.getByText("7")).toBeInTheDocument();
    expect(screen.getByText("2,000")).toBeInTheDocument();
    expect(screen.getByText("turn_completed")).toBeInTheDocument();
    // Identifier links to run detail when project slug present
    const link = screen.getByRole("link", { name: "HAR-44" });
    expect(link).toHaveAttribute("href", "/projects/alpha/runs/HAR-44");
  });

  it("renders identifier as plain text when project slug absent", () => {
    render(
      <MemoryRouter>
        <ActiveRuns
          rows={[
            {
              issue_id: "i2",
              issue_identifier: "HAR-55",
              state: "running",
              worker_host: null,
              workspace_path: null,
              session_id: null,
              turn_count: 0,
              last_event: null,
              last_message: null,
              started_at: "2026-06-12T00:00:00Z",
              last_event_at: null,
              tokens: { input_tokens: 0, output_tokens: 0, total_tokens: 0 },
              project: null,
            },
          ]}
        />
      </MemoryRouter>,
    );
    expect(screen.getByText("HAR-55")).toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "HAR-55" })).not.toBeInTheDocument();
  });

  it("renders an empty message without rows", () => {
    render(
      <MemoryRouter>
        <ActiveRuns rows={[]} />
      </MemoryRouter>,
    );
    expect(screen.getByText(/no runs in progress/i)).toBeInTheDocument();
  });
});
