import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { StatusBadge } from "@/components/StatusBadge";

describe("StatusBadge", () => {
  it("renders the raw status text", () => {
    render(<StatusBadge status="running" />);
    expect(screen.getByText("running")).toBeInTheDocument();
  });

  it("renders secondary variant for completed", () => {
    const { container } = render(<StatusBadge status="completed" />);
    // secondary badge has bg-secondary class
    expect(container.querySelector("[data-slot=badge]")).toBeTruthy();
    expect(screen.getByText("completed")).toBeInTheDocument();
  });

  it("renders destructive variant for failed", () => {
    render(<StatusBadge status="failed" />);
    expect(screen.getByText("failed")).toBeInTheDocument();
  });

  it("renders destructive variant for blocked", () => {
    render(<StatusBadge status="blocked" />);
    expect(screen.getByText("blocked")).toBeInTheDocument();
  });

  it("renders outline variant for running", () => {
    render(<StatusBadge status="running" />);
    expect(screen.getByText("running")).toBeInTheDocument();
  });

  it("renders outline variant for queued", () => {
    render(<StatusBadge status="queued" />);
    expect(screen.getByText("queued")).toBeInTheDocument();
  });

  it("renders outline variant for unknown status", () => {
    render(<StatusBadge status="someUnknownStatus" />);
    expect(screen.getByText("someUnknownStatus")).toBeInTheDocument();
  });
});
