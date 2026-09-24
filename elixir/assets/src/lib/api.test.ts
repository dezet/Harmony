import { describe, it, expect, vi, afterEach } from "vitest";
import { getState, getCase, listCaseEvents, listCases, getProjectSummary, getWorkRuns, getRunDetail, getRunStream, getProjectArtifacts, getProjectActivity, getArtifactUrl, stopRun, retryRun, ApiError } from "@/lib/api";
import projectSummaryFixture from "@/test/fixtures/project_summary.fixture.json";
import workRunsPageFixture from "@/test/fixtures/work_runs_page.fixture.json";
import runDetailFixture from "@/test/fixtures/run_detail.fixture.json";
import runStreamPageFixture from "@/test/fixtures/run_stream_page.fixture.json";
import projectArtifactsFixture from "@/test/fixtures/project_artifacts_page.fixture.json";
import projectActivityFixture from "@/test/fixtures/project_activity_page.fixture.json";

afterEach(() => vi.restoreAllMocks());

describe("api client", () => {
  it("getState returns parsed JSON", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ generated_at: "2026-06-02T00:00:00Z" }), {
            status: 200,
            headers: { "content-type": "application/json" },
          }),
      ),
    );

    const state = await getState();
    expect(state.generated_at).toBe("2026-06-02T00:00:00Z");
  });

  it("throws ApiError with code on error envelope", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ error: { code: "not_found", message: "nope" } }), {
            status: 404,
            headers: { "content-type": "application/json" },
          }),
      ),
    );

    await expect(getState()).rejects.toMatchObject({ code: "not_found", status: 404 });
    await expect(getState()).rejects.toBeInstanceOf(ApiError);
  });
});

describe("getProjectSummary", () => {
  afterEach(() => vi.restoreAllMocks());

  it("requests the correct URL and returns parsed summary", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(projectSummaryFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const summary = await getProjectSummary("alpha");

    expect(fetchMock).toHaveBeenCalledOnce();
    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/projects/alpha/summary");
    expect(summary.project.slug).toBe("alpha");
    expect(summary.counts.running).toBe(1);
  });

  it("encodes special characters in the ref", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(projectSummaryFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await getProjectSummary("my project/ref");

    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/projects/my%20project%2Fref/summary");
  });

  it("throws ApiError on 404 envelope", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ error: { code: "not_found", message: "Project not found" } }), {
            status: 404,
            headers: { "content-type": "application/json" },
          }),
      ),
    );

    await expect(getProjectSummary("unknown")).rejects.toMatchObject({
      code: "not_found",
      status: 404,
    });
    await expect(getProjectSummary("unknown")).rejects.toBeInstanceOf(ApiError);
  });
});

describe("getWorkRuns", () => {
  afterEach(() => vi.restoreAllMocks());

  it("requests the correct URL with project param", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(workRunsPageFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const page = await getWorkRuns("alpha", {});

    expect(fetchMock).toHaveBeenCalledOnce();
    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/work_runs?project=alpha");
    expect(page.work_runs).toHaveLength(2);
    expect(page.meta.page_size).toBe(25);
  });

  it("includes status filter when provided", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(workRunsPageFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await getWorkRuns("alpha", { status: "completed" });

    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toContain("status=completed");
    expect(url).toContain("project=alpha");
  });

  it("includes cursor param when provided", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(workRunsPageFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await getWorkRuns("alpha", {}, "abc123cursor");

    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toContain("cursor=abc123cursor");
  });

  it("throws ApiError on error envelope", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ error: { code: "not_found", message: "Project not found" } }), {
            status: 404,
            headers: { "content-type": "application/json" },
          }),
      ),
    );

    await expect(getWorkRuns("unknown", {})).rejects.toMatchObject({
      code: "not_found",
      status: 404,
    });
    await expect(getWorkRuns("unknown", {})).rejects.toBeInstanceOf(ApiError);
  });
});

describe("getRunDetail", () => {
  afterEach(() => vi.restoreAllMocks());

  it("requests the correct URL and returns parsed run detail", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(runDetailFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const detail = await getRunDetail("COD-10");

    expect(fetchMock).toHaveBeenCalledOnce();
    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/runs/COD-10");
    expect(detail.identifier).toBe("COD-10");
    expect(detail.status).toBe("running");
  });

  it("encodes special characters in the identifier", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(runDetailFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await getRunDetail("PROJ/42");

    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/runs/PROJ%2F42");
  });

  it("throws ApiError on error envelope", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ error: { code: "run_not_found", message: "Run not found" } }), {
            status: 404,
            headers: { "content-type": "application/json" },
          }),
      ),
    );

    await expect(getRunDetail("UNKNOWN-99")).rejects.toMatchObject({
      code: "run_not_found",
      status: 404,
    });
    await expect(getRunDetail("UNKNOWN-99")).rejects.toBeInstanceOf(ApiError);
  });
});

describe("getRunStream", () => {
  afterEach(() => vi.restoreAllMocks());

  it("requests the correct URL without cursor", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(runStreamPageFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const page = await getRunStream("COD-10");

    expect(fetchMock).toHaveBeenCalledOnce();
    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/runs/COD-10/stream");
    expect(page.items).toHaveLength(2);
    expect(page.meta.has_live).toBe(true);
  });

  it("includes cursor param when provided", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(runStreamPageFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await getRunStream("COD-10", "abc123cursor");

    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/runs/COD-10/stream?cursor=abc123cursor");
  });

  it("encodes special characters in the identifier", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(runStreamPageFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await getRunStream("PROJ/42");

    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/runs/PROJ%2F42/stream");
  });

  it("throws ApiError on error envelope", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ error: { code: "run_not_found", message: "Run not found" } }), {
            status: 404,
            headers: { "content-type": "application/json" },
          }),
      ),
    );

    await expect(getRunStream("UNKNOWN-99")).rejects.toMatchObject({
      code: "run_not_found",
      status: 404,
    });
    await expect(getRunStream("UNKNOWN-99")).rejects.toBeInstanceOf(ApiError);
  });
});

describe("getProjectArtifacts", () => {
  afterEach(() => vi.restoreAllMocks());

  it("requests the correct URL and returns parsed artifacts page", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(projectArtifactsFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const page = await getProjectArtifacts("alpha");

    expect(fetchMock).toHaveBeenCalledOnce();
    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/projects/alpha/artifacts");
    expect(page.artifacts).toHaveLength(2);
    expect(page.artifacts[0].kind).toBe("screenshot");
  });

  it("encodes special characters in the slug", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(projectArtifactsFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await getProjectArtifacts("my project/slug");

    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/projects/my%20project%2Fslug/artifacts");
  });

  it("throws ApiError on error envelope", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ error: { code: "not_found", message: "Project not found" } }), {
            status: 404,
            headers: { "content-type": "application/json" },
          }),
      ),
    );

    await expect(getProjectArtifacts("unknown")).rejects.toMatchObject({
      code: "not_found",
      status: 404,
    });
    await expect(getProjectArtifacts("unknown")).rejects.toBeInstanceOf(ApiError);
  });
});

describe("getProjectActivity", () => {
  afterEach(() => vi.restoreAllMocks());

  it("requests the correct URL without cursor", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(projectActivityFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const page = await getProjectActivity("alpha");

    expect(fetchMock).toHaveBeenCalledOnce();
    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/projects/alpha/activity");
    expect(page.items).toHaveLength(2);
  });

  it("includes cursor param when provided", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify(projectActivityFixture), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await getProjectActivity("alpha", "abc123cursor");

    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/projects/alpha/activity?cursor=abc123cursor");
  });

  it("throws ApiError on error envelope", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ error: { code: "not_found", message: "Project not found" } }), {
            status: 404,
            headers: { "content-type": "application/json" },
          }),
      ),
    );

    await expect(getProjectActivity("unknown")).rejects.toMatchObject({
      code: "not_found",
      status: 404,
    });
    await expect(getProjectActivity("unknown")).rejects.toBeInstanceOf(ApiError);
  });
});

describe("getArtifactUrl", () => {
  it("returns the correct URL for an artifact id", () => {
    expect(getArtifactUrl("art-uuid-1")).toBe("/api/v1/artifacts/art-uuid-1");
  });

  it("encodes special characters in the artifact id", () => {
    expect(getArtifactUrl("art/with spaces")).toBe("/api/v1/artifacts/art%2Fwith%20spaces");
  });
});

describe("stopRun", () => {
  afterEach(() => vi.restoreAllMocks());

  it("POSTs to the correct URL and returns status", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify({ status: "stopped" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const result = await stopRun("COD-10");

    expect(fetchMock).toHaveBeenCalledOnce();
    const lastCall = fetchMock.mock.lastCall as unknown[];
    expect(lastCall[0] as string).toBe("/api/v1/runs/COD-10/stop");
    expect((lastCall[1] as RequestInit).method).toBe("POST");
    expect(result.status).toBe("stopped");
  });

  it("encodes special characters in the identifier", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify({ status: "stopped" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await stopRun("PROJ/42");

    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/runs/PROJ%2F42/stop");
  });

  it("throws ApiError on error envelope", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({ error: { code: "run_not_found", message: "Run not found" } }),
            { status: 404, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    await expect(stopRun("UNKNOWN-99")).rejects.toMatchObject({
      code: "run_not_found",
      status: 404,
    });
    await expect(stopRun("UNKNOWN-99")).rejects.toBeInstanceOf(ApiError);
  });

  it("throws ApiError with already_terminal code on 409", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({ error: { code: "already_terminal", message: "Run already completed" } }),
            { status: 409, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    await expect(stopRun("COD-10")).rejects.toMatchObject({
      code: "already_terminal",
      status: 409,
    });
  });
});

describe("retryRun", () => {
  afterEach(() => vi.restoreAllMocks());

  it("POSTs to the correct URL and returns status", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify({ status: "retrying" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const result = await retryRun("COD-10");

    expect(fetchMock).toHaveBeenCalledOnce();
    const lastCall = fetchMock.mock.lastCall as unknown[];
    expect(lastCall[0] as string).toBe("/api/v1/runs/COD-10/retry");
    expect((lastCall[1] as RequestInit).method).toBe("POST");
    expect(result.status).toBe("retrying");
  });

  it("encodes special characters in the identifier", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify({ status: "retrying" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await retryRun("PROJ/42");

    const url = (fetchMock.mock.lastCall as unknown[])[0] as string;
    expect(url).toBe("/api/v1/runs/PROJ%2F42/retry");
  });

  it("throws ApiError on error envelope", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({ error: { code: "run_not_found", message: "Run not found" } }),
            { status: 404, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    await expect(retryRun("UNKNOWN-99")).rejects.toMatchObject({
      code: "run_not_found",
      status: 404,
    });
    await expect(retryRun("UNKNOWN-99")).rejects.toBeInstanceOf(ApiError);
  });

  it("throws ApiError with not_retrying code on 409", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({ error: { code: "not_retrying", message: "Run is not in retrying state" } }),
            { status: 409, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    await expect(retryRun("COD-10")).rejects.toMatchObject({
      code: "not_retrying",
      status: 409,
    });
  });
});

// ─── Intake API: CSRF bootstrap and operator mutations ─────────────────────

type ApiModule = typeof import("@/lib/api");

interface Call {
  url: string;
  init: RequestInit;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function header(init: RequestInit, name: string): string | null {
  return new Headers(init.headers).get(name);
}

function scriptedFetch(responses: Array<(call: Call) => Response>) {
  const calls: Call[] = [];
  const fetchMock = vi.fn(async (url: string, init: RequestInit = {}) => {
    const call = { url, init };
    calls.push(call);
    const next = responses.shift();
    if (!next) throw new Error(`unexpected request ${url}`);
    return next(call);
  });
  vi.stubGlobal("fetch", fetchMock);
  return calls;
}

async function freshApi(): Promise<ApiModule> {
  vi.resetModules();
  return import("@/lib/api");
}

const RULE_ID = "55555555-5555-4555-8555-555555555555";
const CONNECTION_ID = "44444444-4444-4444-8444-444444444444";

describe("intake operator mutations", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("bootstraps the CSRF token once and sends it only in the X-CSRF-Token header", async () => {
    const api = await freshApi();
    const calls = scriptedFetch([
      () => jsonResponse({ csrf_token: "token-1" }),
      () => jsonResponse({ rule: { id: RULE_ID } }, 202),
      () => jsonResponse({ rule: { id: RULE_ID } }),
    ]);

    await api.activateAutomation(RULE_ID, { version: 3, confirmed: true });
    await api.pauseAutomation(RULE_ID, { version: 3 });

    expect(calls.map((c) => c.url)).toEqual([
      "/api/v1/csrf",
      `/api/v1/automations/${RULE_ID}/activate`,
      `/api/v1/automations/${RULE_ID}/pause`,
    ]);
    expect(calls[0].init.credentials).toBe("same-origin");
    expect(calls[0].init.cache).toBe("no-store");

    const activate = calls[1];
    expect(activate.init.method).toBe("POST");
    expect(activate.init.credentials).toBe("same-origin");
    expect(header(activate.init, "x-csrf-token")).toBe("token-1");
    expect(header(activate.init, "content-type")).toBe("application/json");
    expect(JSON.parse(activate.init.body as string)).toEqual({ version: 3, confirmed: true });
    expect(activate.url).not.toContain("token-1");
    expect(header(calls[2].init, "x-csrf-token")).toBe("token-1");

    expect(window.localStorage.length).toBe(0);
    expect(window.sessionStorage.length).toBe(0);
    expect(document.cookie).not.toContain("token-1");
  });

  it("reads never fetch or send the CSRF token", async () => {
    const api = await freshApi();
    const calls = scriptedFetch([() => jsonResponse({ items: [], meta: { next_cursor: null, page_size: 25 } })]);

    await api.listAutomations({ project: "11111111-1111-4111-8111-111111111111", cursor: "abc" });

    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("/api/v1/automations?project=11111111-1111-4111-8111-111111111111&cursor=abc");
    expect(header(calls[0].init, "x-csrf-token")).toBeNull();
  });

  it("after a session restart a 403 refreshes the token but never repeats the mutation", async () => {
    const api = await freshApi();
    const calls = scriptedFetch([
      () => jsonResponse({ csrf_token: "stale-token" }),
      () => jsonResponse({ error: { code: "csrf_invalid", message: "Missing or invalid CSRF token", fields: {} } }, 403),
      () => jsonResponse({ csrf_token: "fresh-token" }),
      () => jsonResponse({ rule: { id: RULE_ID } }),
    ]);

    await expect(api.pauseAutomation(RULE_ID, { version: 2 })).rejects.toMatchObject({
      status: 403,
      code: "csrf_invalid",
    });

    expect(calls.map((c) => c.url)).toEqual([
      "/api/v1/csrf",
      `/api/v1/automations/${RULE_ID}/pause`,
      "/api/v1/csrf",
    ]);

    await api.pauseAutomation(RULE_ID, { version: 2 });
    expect(calls).toHaveLength(4);
    expect(header(calls[3].init, "x-csrf-token")).toBe("fresh-token");
  });

  it("does not send the mutation when the token cannot be obtained", async () => {
    const api = await freshApi();
    const calls = scriptedFetch([() => jsonResponse({ error: { code: "not_found" } }, 404)]);

    await expect(api.acknowledgeCase("jira_1", { expected_version: 1 })).rejects.toBeInstanceOf(api.ApiError);
    expect(calls.map((c) => c.url)).toEqual(["/api/v1/csrf"]);
  });

  it("test-send carries the form Idempotency-Key and an explicit confirmation", async () => {
    const api = await freshApi();
    const key = "0b9d6f5e-3c1a-4a51-9d7e-6f1c2b3a4d5e";
    const calls = scriptedFetch([
      () => jsonResponse({ csrf_token: "token-1" }),
      () => jsonResponse({ test_delivery: { id: "d1", status: "pending" } }, 202),
    ]);

    const result = await api.testSendIntegration(CONNECTION_ID, {
      recipient: "+48600100200",
      confirmed: true,
      idempotencyKey: key,
    });

    expect(result.test_delivery.id).toBe("d1");
    const send = calls[1];
    expect(send.url).toBe(`/api/v1/integrations/${CONNECTION_ID}/test-send`);
    expect(header(send.init, "idempotency-key")).toBe(key);
    expect(JSON.parse(send.init.body as string)).toEqual({ recipient: "+48600100200", confirmed: true });
  });

  it("maps the remaining intake endpoints to their contract paths", async () => {
    const api = await freshApi();
    const calls = scriptedFetch([
      () => jsonResponse({ csrf_token: "token-1" }),
      () => jsonResponse({ rule: {} }, 201),
      () => jsonResponse({ rule: {} }),
      () => jsonResponse({ sample: [] }),
      () => jsonResponse({ status: "accepted" }, 202),
      () => jsonResponse({ accepted_rule_ids: [], skipped: [] }, 202),
      () => jsonResponse({ connection: {} }, 201),
      () => jsonResponse({ connection: {} }),
      () => jsonResponse({ health: "ok" }),
      () => jsonResponse({ label_id: "l1", created: false }),
      () => jsonResponse({ status: "approved" }),
      () => jsonResponse({ analysis_version: 2 }, 202),
      () => jsonResponse({ delivery: {} }, 202),
      () => jsonResponse({ items: [], meta: { next_cursor: null } }),
      () => jsonResponse({ items: [] }),
      () => jsonResponse({ teams: [] }),
    ]);

    await api.createAutomation({ name: "Rule" } as never);
    await api.updateAutomation(RULE_ID, { version: 1, interval_seconds: 600 });
    await api.previewAutomation(RULE_ID);
    await api.checkAutomation(RULE_ID);
    await api.checkAutomations();
    await api.createIntegration({ kind: "smsapi", name: "SMS", settings: { sender: "Harmony" }, secret: "s" });
    await api.updateIntegration(CONNECTION_ID, { version: 1, clear_secret: true });
    await api.testIntegration(CONNECTION_ID);
    await api.createLinearHoldLabel("p/1", { team_id: "t1", confirmed: true });
    await api.approveRepair("jira_1", { expected_version: 2, analysis_version: 1, confirmed: true });
    await api.reanalyzeCase("jira_1", { expected_version: 2, confirmed: true });
    await api.retryDelivery("d/1", { expected_status: "unknown", confirm_duplicate_risk: true });
    await api.listJiraBoards(CONNECTION_ID, { q: "ops board", cursor: "c1" });
    await api.listJiraPriorities(CONNECTION_ID);
    await api.getLinearOptions("p/1");

    expect(calls.map((c) => `${c.init.method ?? "GET"} ${c.url}`)).toEqual([
      "GET /api/v1/csrf",
      "POST /api/v1/automations",
      `PATCH /api/v1/automations/${RULE_ID}`,
      `POST /api/v1/automations/${RULE_ID}/preview`,
      `POST /api/v1/automations/${RULE_ID}/check`,
      "POST /api/v1/automations/check",
      "POST /api/v1/integrations",
      `PATCH /api/v1/integrations/${CONNECTION_ID}`,
      `POST /api/v1/integrations/${CONNECTION_ID}/test`,
      "POST /api/v1/projects/p%2F1/linear-hold-label",
      "POST /api/v1/cases/jira_1/approve-repair",
      "POST /api/v1/cases/jira_1/reanalyze",
      "POST /api/v1/deliveries/d%2F1/retry",
      `GET /api/v1/integrations/${CONNECTION_ID}/jira/boards?q=ops+board&cursor=c1`,
      `GET /api/v1/integrations/${CONNECTION_ID}/jira/priorities`,
      "GET /api/v1/projects/p%2F1/linear-options",
    ]);

    const mutations = calls.slice(1, 13);
    expect(mutations.every((c) => header(c.init, "x-csrf-token") === "token-1")).toBe(true);
    expect(calls.slice(13).every((c) => header(c.init, "x-csrf-token") === null)).toBe(true);
  });
});

describe("case center reads", () => {
  afterEach(() => vi.unstubAllGlobals());

  function recordFetch() {
    const calls: { url: string; init: RequestInit | undefined }[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        calls.push({ url: String(input), init });
        return new Response(JSON.stringify({ items: [], meta: { next_cursor: null } }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }),
    );
    return calls;
  }

  it("builds the list query from filters and cursor, skipping empty values", async () => {
    const calls = recordFetch();

    await listCases({ project: "alpha beta", filter: "decision", column: "detected", q: "OPS-1", page_size: 50 }, "c/1");
    await listCases({ project: "", q: undefined });

    expect(calls.map((c) => c.url)).toEqual([
      "/api/v1/cases?project=alpha+beta&filter=decision&column=detected&q=OPS-1&page_size=50&cursor=c%2F1",
      "/api/v1/cases",
    ]);
  });

  it("encodes the ref of the detail and history and pages the history", async () => {
    const calls = recordFetch();

    await getCase("jira_a/b");
    await listCaseEvents("jira_a/b");
    await listCaseEvents("jira_a/b", "c2");

    expect(calls.map((c) => c.url)).toEqual([
      "/api/v1/cases/jira_a%2Fb",
      "/api/v1/cases/jira_a%2Fb/events",
      "/api/v1/cases/jira_a%2Fb/events?cursor=c2",
    ]);
  });

  it("passes the abort signal of the query to fetch", async () => {
    const calls = recordFetch();
    const controller = new AbortController();

    await listCases({}, undefined, controller.signal);
    await getCase("jira_1", controller.signal);
    await listCaseEvents("jira_1", undefined, controller.signal);

    expect(calls.every((c) => c.init?.signal === controller.signal)).toBe(true);
  });
});
