import { render, screen } from "@testing-library/react";
import { describe, it, expect } from "vitest";
import { WorkRunsTable } from "@/features/dashboard/components/WorkRunsTable";
import type { DurableWorkRun } from "@/types/contract";

const run: DurableWorkRun = {
  id: "wr1",
  project_id: "project-1",
  type: "implementation",
  status: "open",
  dedupe_key: "key-1",
  github_owner: "dezet",
  github_repo: "portal",
  github_pr_number: 42,
  github_head_sha: "abc123",
  github_head_ref: "cod-9",
  github_base_ref: "develop",
  linear_issue_id: "issue-9",
  linear_identifier: "COD-9",
  linear_url: "https://linear.test/COD-9",
  agent_backend: "codex",
  payload: { project_id: "project-1" },
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
