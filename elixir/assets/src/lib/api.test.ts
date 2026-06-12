import { describe, it, expect, vi, afterEach } from "vitest";
import { getState, getProjectSummary, getWorkRuns, ApiError } from "@/lib/api";
import projectSummaryFixture from "@/test/fixtures/project_summary.fixture.json";
import workRunsPageFixture from "@/test/fixtures/work_runs_page.fixture.json";

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
