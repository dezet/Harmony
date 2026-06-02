import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { MetricCards } from "@/features/dashboard/components/MetricCards";
import type { StatePayload } from "@/types/contract";

const state: StatePayload = {
  generated_at: "2026-06-02T00:00:00Z",
  counts: { running: 2, retrying: 1, blocked: 3 },
  codex_totals: { input_tokens: 10, output_tokens: 20, total_tokens: 30, seconds_running: 0 },
};

describe("MetricCards", () => {
  it("renders the running/retrying/blocked counts and token total", () => {
    render(<MetricCards state={state} />);
    // Values are distinct in this fixture, so presence checks are unambiguous.
    expect(screen.getByText("Running")).toBeInTheDocument();
    expect(screen.getByText("2")).toBeInTheDocument();
    expect(screen.getByText("Retrying")).toBeInTheDocument();
    expect(screen.getByText("1")).toBeInTheDocument();
    expect(screen.getByText("Blocked")).toBeInTheDocument();
    expect(screen.getByText("3")).toBeInTheDocument();
    expect(screen.getByText("Total tokens")).toBeInTheDocument();
    expect(screen.getByText("30")).toBeInTheDocument();
  });
});
