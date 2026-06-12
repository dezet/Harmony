import { render, screen } from "@testing-library/react";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { ElapsedTime } from "@/components/ElapsedTime";

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-06-12T12:01:05Z"));
});
afterEach(() => vi.useRealTimers());

describe("ElapsedTime", () => {
  it("renders the elapsed duration since the timestamp", () => {
    render(<ElapsedTime since="2026-06-12T12:00:00Z" />);
    expect(screen.getByText("1m 5s")).toBeInTheDocument();
  });

  it("renders a dash when there is no timestamp", () => {
    render(<ElapsedTime since={null} />);
    expect(screen.getByText("—")).toBeInTheDocument();
  });
});
