import { render, screen, fireEvent } from "@testing-library/react";
import { describe, it, expect, vi } from "vitest";
import { RunStream } from "@/features/run/components/RunStream";
import type { RunStreamItem } from "@/types/contract";

function makeItem(
  id: string,
  kind: "work_event" | "live_event",
  type: string,
  at: string,
): RunStreamItem {
  return { id, kind, type, at, payload: null };
}

const WORK_ITEMS: RunStreamItem[] = [
  makeItem("1", "work_event", "turn_start", "2026-06-13T10:00:01Z"),
  makeItem("2", "work_event", "turn_end", "2026-06-13T10:00:02Z"),
];

const MIXED_ITEMS: RunStreamItem[] = [
  makeItem("1", "work_event", "turn_start", "2026-06-13T10:00:01Z"),
  makeItem("2", "live_event", "tool_use", "2026-06-13T10:00:02Z"),
];

const defaultProps = {
  items: [] as RunStreamItem[],
  isLoading: false,
  error: null,
  onRetry: vi.fn(),
  hasNextPage: false,
  onLoadMore: vi.fn(),
};

describe("RunStream", () => {
  it("shows 'No events yet.' when empty and not loading", () => {
    render(<RunStream {...defaultProps} items={[]} />);
    expect(screen.getByText("No events yet.")).toBeInTheDocument();
  });

  it("shows skeletons when loading and empty", () => {
    const { container } = render(
      <RunStream {...defaultProps} isLoading={true} items={[]} />,
    );
    expect(container.querySelectorAll("[data-slot=skeleton]").length).toBeGreaterThan(0);
  });

  it("shows error alert when error is present", () => {
    render(
      <RunStream
        {...defaultProps}
        error={new Error("Failed to load")}
        items={[]}
      />,
    );
    expect(screen.getByRole("alert")).toBeInTheDocument();
    expect(screen.getByText(/Failed to load/)).toBeInTheDocument();
  });

  it("calls onRetry when Retry button is clicked", () => {
    const onRetry = vi.fn();
    render(
      <RunStream
        {...defaultProps}
        error={new Error("Failed")}
        items={[]}
        onRetry={onRetry}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /retry/i }));
    expect(onRetry).toHaveBeenCalledOnce();
  });

  it("renders items in ascending order", () => {
    render(<RunStream {...defaultProps} items={WORK_ITEMS} />);
    const rows = screen.getAllByText(/turn_start|turn_end/);
    // turn_start (first/oldest) should appear before turn_end (newer)
    const startIdx = rows.findIndex((el) => el.textContent === "turn_start");
    const endIdx = rows.findIndex((el) => el.textContent === "turn_end");
    expect(startIdx).toBeLessThan(endIdx);
  });

  it("shows 'Load more' button at BOTTOM when hasNextPage", () => {
    render(<RunStream {...defaultProps} items={WORK_ITEMS} hasNextPage={true} />);
    expect(screen.getByRole("button", { name: /load more/i })).toBeInTheDocument();
  });

  it("does NOT show 'Load more' when hasNextPage is false", () => {
    render(<RunStream {...defaultProps} items={WORK_ITEMS} hasNextPage={false} />);
    expect(screen.queryByRole("button", { name: /load more/i })).not.toBeInTheDocument();
  });

  it("calls onLoadMore when Load more button is clicked", () => {
    const onLoadMore = vi.fn();
    render(
      <RunStream
        {...defaultProps}
        items={WORK_ITEMS}
        hasNextPage={true}
        onLoadMore={onLoadMore}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /load more/i }));
    expect(onLoadMore).toHaveBeenCalledOnce();
  });

  it("does NOT show filter buttons when only work_events present", () => {
    render(<RunStream {...defaultProps} items={WORK_ITEMS} />);
    expect(screen.queryByRole("button", { name: /^all$/i })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /^events$/i })).not.toBeInTheDocument();
  });

  it("shows filter buttons All and Events when both kinds present", () => {
    render(<RunStream {...defaultProps} items={MIXED_ITEMS} />);
    expect(screen.getByRole("button", { name: /^all$/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /^events$/i })).toBeInTheDocument();
  });

  it("filters out live_events when Events filter is active", () => {
    render(<RunStream {...defaultProps} items={MIXED_ITEMS} />);
    fireEvent.click(screen.getByRole("button", { name: /^events$/i }));
    // turn_start (work_event) should still be visible
    expect(screen.getByText("turn_start")).toBeInTheDocument();
    // tool_use (live_event) should be hidden
    expect(screen.queryByText("tool_use")).not.toBeInTheDocument();
  });

  it("shows all items when All filter is clicked after Events", () => {
    render(<RunStream {...defaultProps} items={MIXED_ITEMS} />);
    // Filter down to events only
    fireEvent.click(screen.getByRole("button", { name: /^events$/i }));
    expect(screen.queryByText("tool_use")).not.toBeInTheDocument();
    // Then click All to show everything again
    fireEvent.click(screen.getByRole("button", { name: /^all$/i }));
    expect(screen.getByText("turn_start")).toBeInTheDocument();
    expect(screen.getByText("tool_use")).toBeInTheDocument();
  });

  it("renders the stream card with title 'Stream'", () => {
    render(<RunStream {...defaultProps} items={WORK_ITEMS} />);
    expect(screen.getByText("Stream")).toBeInTheDocument();
  });
});
