import { describe, expect, it } from "vitest";
import fixture from "@/test/fixtures/state_payload.fixture.json";
import type { StatePayload } from "@/types/contract";

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
