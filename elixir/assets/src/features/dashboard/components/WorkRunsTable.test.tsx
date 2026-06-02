import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { WorkRunsTable } from "@/features/dashboard/components/WorkRunsTable";
import type { DurableWorkRun } from "@/types/contract";

const run: DurableWorkRun = {
  id: "wr1",
  type: "implementation",
  status: "open",
  dedupe_key: "key-1",
  github_owner: "dezet",
  github_repo: "portal",
  github_pr_number: 42,
  linear_identifier: "COD-9",
};

describe("WorkRunsTable", () => {
  it("renders a work run row with repo/PR reference", () => {
    render(<WorkRunsTable rows={[run]} />);
    expect(screen.getByText("implementation")).toBeInTheDocument();
    expect(screen.getByText("dezet/portal#42")).toBeInTheDocument();
    expect(screen.getByText("COD-9")).toBeInTheDocument();
  });

  it("renders an empty state when there are no rows", () => {
    render(<WorkRunsTable rows={[]} />);
    expect(screen.getByText(/no work runs/i)).toBeInTheDocument();
  });
});
