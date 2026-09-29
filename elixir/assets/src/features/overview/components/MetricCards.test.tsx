import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { MetricCards } from "@/features/overview/components/MetricCards";
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
    expect(screen.getByText("W toku")).toBeInTheDocument();
    expect(screen.getByText("2")).toBeInTheDocument();
    expect(screen.getByText("Ponawiane")).toBeInTheDocument();
    expect(screen.getByText("1")).toBeInTheDocument();
    expect(screen.getByText("Zablokowane")).toBeInTheDocument();
    expect(screen.getByText("3")).toBeInTheDocument();
    expect(screen.getByText("Tokeny łącznie")).toBeInTheDocument();
    expect(screen.getByText("30")).toBeInTheDocument();
  });
});
