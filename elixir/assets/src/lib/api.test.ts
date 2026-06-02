import { describe, it, expect, vi, afterEach } from "vitest";
import { getState, ApiError } from "@/lib/api";

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
