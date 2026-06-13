import { describe, expect, it } from "vitest";
import fixture from "@/test/fixtures/state_payload.fixture.json";
import projectSummaryFixture from "@/test/fixtures/project_summary.fixture.json";
import workRunsPageFixture from "@/test/fixtures/work_runs_page.fixture.json";
import runDetailFixture from "@/test/fixtures/run_detail.fixture.json";
import runStreamPageFixture from "@/test/fixtures/run_stream_page.fixture.json";
import type {
  ProjectSummary,
  RunDetail,
  RunStreamPage,
  StatePayload,
  WorkRunsPage,
} from "@/types/contract";

function expectKeys(value: object | undefined, keys: string[]) {
  expect(Object.keys(value ?? {}).sort()).toEqual([...keys].sort());
}

describe("StatePayload contract fixture", () => {
  it("type-checks and exposes all durable lists used by the backend presenter", () => {
    const payload: StatePayload = fixture;
    const durableKeys = Object.keys(payload.durable ?? {}).sort();

    expect(durableKeys).toEqual([
      "artifacts",
      "blockers",
      "dedupe_keys",
      "projects",
      "pull_request_links",
      "work_events",
      "work_runs",
    ]);
    expectKeys(payload.durable?.projects?.[0], [
      "config_version",
      "github",
      "id",
      "linear",
      "slug",
    ]);
    expectKeys(payload.durable?.projects?.[0]?.linear, [
      "human_review_state",
      "project_slug",
      "team_key",
    ]);
    expectKeys(payload.durable?.projects?.[0]?.github, [
      "base_branch",
      "owner",
      "repo",
    ]);
    expectKeys(payload.durable?.work_runs?.[0], [
      "agent_backend",
      "dedupe_key",
      "github_base_ref",
      "github_head_ref",
      "github_head_sha",
      "github_owner",
      "github_pr_number",
      "github_repo",
      "id",
      "linear_identifier",
      "linear_issue_id",
      "linear_url",
      "payload",
      "project_id",
      "status",
      "type",
    ]);
    expectKeys(payload.durable?.pull_request_links?.[0], [
      "github_base_ref",
      "github_head_ref",
      "github_head_sha",
      "github_owner",
      "github_pr_number",
      "github_repo",
      "id",
      "linear_identifier",
      "linear_issue_id",
      "linear_url",
      "metadata",
      "project_id",
    ]);
    expectKeys(payload.durable?.blockers?.[0], [
      "id",
      "metadata",
      "project_id",
      "reason",
      "status",
      "target_id",
      "target_type",
      "work_run_id",
    ]);
    expectKeys(payload.durable?.dedupe_keys?.[0], [
      "id",
      "key",
      "metadata",
      "project_id",
      "scope",
      "status",
    ]);
    expectKeys(payload.durable?.work_events?.[0], [
      "id",
      "inserted_at",
      "payload",
      "project_id",
      "type",
      "work_run_id",
    ]);
    expectKeys(payload.durable?.artifacts?.[0], [
      "id",
      "kind",
      "metadata",
      "path",
      "project_id",
      "work_run_id",
    ]);
    expect(payload.running?.[0]?.issue_identifier).toBe("COD-1");
    expect(payload.artifacts?.[0]?.path).toBe(".harmony/artifacts/runtime.png");
    expect(payload.durable?.projects?.[0]?.github.base_branch).toBe("develop");
    expect(payload.durable?.pull_request_links?.[0]?.github_pr_number).toBe(17);
    expect(payload.durable?.blockers?.[0]?.reason).toBe("missing_required_evidence:browser");
    expect(payload.durable?.dedupe_keys?.[0]?.key).toBe("linear:issue-1");
    expect(payload.durable?.work_events?.[0]?.type).toBe("linear_state_updated");
    expect(payload.durable?.artifacts?.[0]?.metadata).toMatchObject({
      description: "Durable screenshot",
    });
  });
});

describe("ProjectSummary contract fixture", () => {
  it("type-checks and exposes all fields used by the summary endpoint", () => {
    const summary: ProjectSummary = projectSummaryFixture;

    expectKeys(summary.project, [
      "id",
      "slug",
      "github_owner",
      "github_repo",
      "github_base_branch",
      "linear_project_slug",
      "linear_team_key",
      "linear_human_review_state",
      "config_version",
    ]);
    expectKeys(summary.counts, ["running", "retrying", "blocked"]);
    expect(summary.running).toHaveLength(1);
    expectKeys(summary.running[0], [
      "issue_id",
      "issue_identifier",
      "state",
      "worker_host",
      "workspace_path",
      "session_id",
      "turn_count",
      "last_event",
      "last_message",
      "started_at",
      "last_event_at",
      "tokens",
    ]);
    expect(summary.retrying).toHaveLength(1);
    expectKeys(summary.retrying[0], [
      "issue_id",
      "issue_identifier",
      "attempt",
      "due_at",
      "error",
      "worker_host",
      "workspace_path",
    ]);
    expect(summary.blocked).toHaveLength(1);
    expectKeys(summary.blocked[0], [
      "issue_id",
      "issue_identifier",
      "state",
      "error",
      "worker_host",
      "workspace_path",
      "session_id",
      "blocked_at",
      "last_event",
      "last_message",
      "last_event_at",
    ]);
    expect(summary.human_review_prs).toHaveLength(1);
    expectKeys(summary.human_review_prs[0], [
      "id",
      "github_owner",
      "github_repo",
      "github_pr_number",
      "github_head_sha",
      "github_head_ref",
      "github_base_ref",
      "linear_identifier",
      "linear_url",
      "metadata",
    ]);
    expect(summary.project.slug).toBe("alpha");
    expect(summary.counts.running).toBe(1);
    expect(summary.running[0].issue_identifier).toBe("COD-10");
    expect(summary.human_review_prs[0].github_pr_number).toBe(42);
  });
});

describe("WorkRunsPage contract fixture", () => {
  it("type-checks and exposes all fields used by the work_runs endpoint", () => {
    const page: WorkRunsPage = workRunsPageFixture;

    expect(page.work_runs).toHaveLength(2);
    expectKeys(page.work_runs[0], [
      "id",
      "project_id",
      "type",
      "status",
      "dedupe_key",
      "github_owner",
      "github_repo",
      "github_pr_number",
      "github_head_sha",
      "github_head_ref",
      "github_base_ref",
      "linear_issue_id",
      "linear_identifier",
      "linear_url",
      "agent_backend",
      "inserted_at",
      "updated_at",
    ]);
    expectKeys(page.meta, ["next_cursor", "page_size"]);
    expect(page.work_runs[0].status).toBe("completed");
    expect(page.work_runs[0].inserted_at).toBe("2026-06-13T10:00:02Z");
    expect(page.meta.next_cursor).not.toBeNull();
    expect(page.meta.page_size).toBe(25);
  });
});

describe("RunDetail contract fixture", () => {
  it("type-checks and exposes all fields used by the run detail endpoint", () => {
    const detail: RunDetail = runDetailFixture;

    expectKeys(detail, [
      "identifier",
      "issue_id",
      "work_run_id",
      "status",
      "project",
      "workspace",
      "session_id",
      "turn_count",
      "started_at",
      "last_event_at",
      "last_event",
      "last_message",
      "tokens",
      "attempts",
      "pull_requests",
      "artifacts",
      "last_error",
      "stream_cursor",
    ]);
    expectKeys(detail.project!, ["id", "slug", "name"]);
    expectKeys(detail.workspace!, ["path", "host"]);
    expectKeys(detail.tokens!, ["input_tokens", "output_tokens", "total_tokens"]);
    expectKeys(detail.attempts, ["restart_count", "current_retry_attempt"]);
    expect(detail.pull_requests).toHaveLength(1);
    expectKeys(detail.pull_requests[0], [
      "id",
      "github_owner",
      "github_repo",
      "github_pr_number",
      "github_head_sha",
      "github_head_ref",
      "github_base_ref",
      "linear_identifier",
      "linear_url",
      "metadata",
    ]);
    expect(detail.artifacts).toHaveLength(1);
    expectKeys(detail.artifacts[0], ["id", "kind", "path", "metadata"]);
    expect(detail.identifier).toBe("COD-10");
    expect(detail.issue_id).toBe("issue-cod-10");
    expect(detail.work_run_id).toBe("run-uuid-1");
    expect(detail.status).toBe("running");
    expect(detail.project!.slug).toBe("alpha");
    expect(detail.workspace!.host).toBe("host1");
    expect(detail.tokens!.total_tokens).toBe(280);
    expect(detail.attempts.restart_count).toBeNull();
    expect(detail.last_message).toBeNull();
    expect(detail.last_error).toBeNull();
    expect(detail.pull_requests[0].github_pr_number).toBe(42);
    expect(detail.artifacts[0].kind).toBe("screenshot");
  });
});

describe("RunStreamPage contract fixture", () => {
  it("type-checks and exposes all fields used by the run stream endpoint", () => {
    const page: RunStreamPage = runStreamPageFixture as RunStreamPage;

    expect(page.items).toHaveLength(2);
    expectKeys(page.items[0], ["id", "kind", "type", "at", "payload"]);
    expectKeys(page.meta, ["next_cursor", "has_live"]);
    expect(page.items[0].id).toBe("evt-uuid-1");
    expect(page.items[0].kind).toBe("work_event");
    expect(page.items[0].type).toBe("turn_start");
    expect(page.items[0].at).toBe("2026-06-13T10:00:01Z");
    expect(page.items[1].payload).toMatchObject({ message: "Turn completed successfully" });
    expect(page.meta.next_cursor).not.toBeNull();
    expect(page.meta.has_live).toBe(true);
  });
});
