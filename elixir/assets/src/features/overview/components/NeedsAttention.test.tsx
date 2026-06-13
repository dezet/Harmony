import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, it, expect } from "vitest";
import { NeedsAttention } from "@/features/overview/components/NeedsAttention";

describe("NeedsAttention", () => {
  it("renders blocked and retry items with badges", () => {
    render(
      <MemoryRouter>
        <NeedsAttention
          state={{
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
                blocked_at: null,
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
            ],
          }}
        />
      </MemoryRouter>,
    );

    expect(screen.getByText("Blocked")).toBeInTheDocument();
    expect(screen.getByText("sandbox denied")).toBeInTheDocument();
    expect(screen.getByText("Retry failing")).toBeInTheDocument();
    expect(screen.getByText(/agent timeout/)).toBeInTheDocument();
    // HAR-42 has a project slug → should be a link
    const link = screen.getByRole("link", { name: "HAR-42" });
    expect(link).toHaveAttribute("href", "/projects/alpha/runs/HAR-42");
    // HAR-38 has no project slug → plain text
    expect(screen.getByText("HAR-38")).toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "HAR-38" })).not.toBeInTheDocument();
  });

  it("renders the all-clear message when nothing needs attention", () => {
    render(
      <MemoryRouter>
        <NeedsAttention state={{ generated_at: "2026-06-12T00:00:00Z" }} />
      </MemoryRouter>,
    );
    expect(screen.getByText(/all clear/i)).toBeInTheDocument();
  });
});
