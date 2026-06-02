import { describe, it, expect } from "vitest";
import { QueryClient } from "@tanstack/react-query";
import { hydrateFromChannel, DASHBOARD_KEY } from "@/lib/socket";

describe("channel hydration", () => {
  it("writes join state and pushed state into the query cache", () => {
    const qc = new QueryClient();

    // Fake phoenix channel: records the "state" handler and the join callback.
    const handlers: Record<string, (payload: unknown) => void> = {};
    const channel = {
      on: (event: string, cb: (payload: unknown) => void) => {
        handlers[event] = cb;
        return 0;
      },
      join: () => ({
        receive(status: string, cb: (resp: unknown) => void) {
          if (status === "ok") cb({ state: { generated_at: "join" } });
          return this;
        },
      }),
      leave: () => ({ receive: () => undefined }),
    };

    const cleanup = hydrateFromChannel(qc, channel as never);
    expect(qc.getQueryData(DASHBOARD_KEY)).toEqual({ generated_at: "join" });

    handlers["state"]({ generated_at: "push" });
    expect(qc.getQueryData(DASHBOARD_KEY)).toEqual({ generated_at: "push" });

    cleanup();
  });
});
