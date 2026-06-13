import { describe, it, expect, vi, afterEach } from "vitest";
import { getState, getProjectSummary, getWorkRuns, getRunDetail, getRunStream, getProjectArtifacts, getProjectActivity, getArtifactUrl, stopRun, retryRun, ApiError } from "@/lib/api";
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
