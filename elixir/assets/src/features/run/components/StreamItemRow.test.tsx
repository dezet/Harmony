import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { StreamItemRow } from "@/features/run/components/StreamItemRow";
import type { RunStreamItem } from "@/types/contract";

function makeItem(overrides: Partial<RunStreamItem> = {}): RunStreamItem {
  return {
    id: "evt-1",
    kind: "work_event",
    type: "turn_start",
    at: "2026-06-13T10:00:01Z",
    payload: null,
    ...overrides,
  };
}

describe("StreamItemRow", () => {
  it("renders the at timestamp", () => {
    render(<StreamItemRow item={makeItem()} />);
    expect(screen.getByText("2026-06-13T10:00:01Z")).toBeInTheDocument();
  });

  it("renders the type in mono", () => {
    render(<StreamItemRow item={makeItem({ type: "turn_start" })} />);
    expect(screen.getByText("turn_start")).toBeInTheDocument();
  });

  it("renders 'event' badge for work_event kind", () => {
    render(<StreamItemRow item={makeItem({ kind: "work_event" })} />);
    expect(screen.getByText("event")).toBeInTheDocument();
  });

  it("renders 'live' badge for live_event kind", () => {
    render(<StreamItemRow item={makeItem({ kind: "live_event" })} />);
    expect(screen.getByText("live")).toBeInTheDocument();
  });

  it("renders payload.message when it is a string", () => {
    render(
      <StreamItemRow
        item={makeItem({ payload: { message: "Turn completed successfully" } })}
      />,
    );
    expect(screen.getByText("Turn completed successfully")).toBeInTheDocument();
  });

  it("truncates long payload.message strings", () => {
    const long = "a".repeat(200);
    render(<StreamItemRow item={makeItem({ payload: { message: long } })} />);
    // Should not render full 200 char string; instead truncated version
    const msg = screen.queryByText(long);
    expect(msg).not.toBeInTheDocument();
  });

  it("renders compact JSON for non-message object payload", () => {
    render(
      <StreamItemRow
        item={makeItem({ payload: { exit_code: 0, tool: "bash" } })}
      />,
    );
    // Should render JSON summary via the data-testid span
    const summary = screen.getByTestId("payload-summary");
    expect(summary.textContent).toMatch(/exit_code/);
  });

  it("renders nothing extra for null payload", () => {
    const { container } = render(<StreamItemRow item={makeItem({ payload: null })} />);
    // No payload summary rendered
    expect(container.querySelectorAll("[data-testid=payload-summary]")).toHaveLength(0);
  });

  it("renders nothing extra for empty object payload", () => {
    const { container } = render(<StreamItemRow item={makeItem({ payload: {} })} />);
    expect(container.querySelectorAll("[data-testid=payload-summary]")).toHaveLength(0);
  });

  it("shows title attr with full JSON on object payload", () => {
    const payload = { exit_code: 0, tool: "bash" };
    const { container } = render(
      <StreamItemRow item={makeItem({ payload })} />,
    );
    const span = container.querySelector("[title]");
    expect(span).toBeTruthy();
    expect(span?.getAttribute("title")).toContain("exit_code");
  });
});
