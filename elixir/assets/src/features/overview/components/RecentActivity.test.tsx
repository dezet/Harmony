import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { RecentActivity } from "@/features/overview/components/RecentActivity";

function event(id: string, type: string, insertedAt: string) {
  return { id, project_id: null, work_run_id: null, type, payload: null, inserted_at: insertedAt };
}

describe("RecentActivity", () => {
  it("renders newest events first, capped at 10", () => {
    const events = Array.from({ length: 12 }, (_, i) =>
      event(`e${i}`, `event_${i}`, `2026-06-12T00:${String(i).padStart(2, "0")}:00Z`),
    );
    render(<RecentActivity events={events} />);

    const items = screen.getAllByRole("listitem");
    expect(items).toHaveLength(10);
    // newest (event_11) first; oldest two (event_0, event_1) dropped
    expect(items[0]).toHaveTextContent("event_11");
    expect(screen.queryByText("event_0")).not.toBeInTheDocument();
  });

  it("renders nothing without events", () => {
    const { container } = render(<RecentActivity events={[]} />);
    expect(container).toBeEmptyDOMElement();
  });
});
