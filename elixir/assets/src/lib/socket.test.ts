import { describe, it, expect, vi } from "vitest";
import { QueryClient } from "@tanstack/react-query";
import { hydrateFromChannel, DASHBOARD_KEY } from "@/lib/socket";

function fakeChannel() {
  const handlers: Record<string, (payload: unknown) => void> = {};
  let joinOk: ((resp: unknown) => void) | undefined;
  let joinError: ((resp: unknown) => void) | undefined;
  let joinTimeout: ((resp: unknown) => void) | undefined;
  let errorHandler: (() => void) | undefined;
  let closeHandler: (() => void) | undefined;

  const channel = {
    on: (event: string, cb: (payload: unknown) => void) => {
      handlers[event] = cb;
      return 0;
    },
    onError: (cb: () => void) => {
      errorHandler = cb;
    },
    onClose: (cb: () => void) => {
      closeHandler = cb;
    },
    join: () => ({
      receive(status: string, cb: (resp: unknown) => void) {
        if (status === "ok") joinOk = cb;
        if (status === "error") joinError = cb;
        if (status === "timeout") joinTimeout = cb;
        return this;
      },
    }),
    leave: vi.fn(() => ({ receive: () => undefined })),
  };

  return {
    channel,
    handlers,
    emitJoinOk: (resp: unknown) => joinOk?.(resp),
    emitJoinError: () => joinError?.({}),
    emitJoinTimeout: () => joinTimeout?.({}),
    emitError: () => errorHandler?.(),
    emitClose: () => closeHandler?.(),
  };
}

describe("channel hydration", () => {
  it("writes join state and pushed state into the query cache", () => {
    const qc = new QueryClient();
    const fake = fakeChannel();

    const cleanup = hydrateFromChannel(qc, fake.channel as never);
    fake.emitJoinOk({ state: { generated_at: "join" } });
    expect(qc.getQueryData(DASHBOARD_KEY)).toEqual({ generated_at: "join" });

    fake.handlers["state"]({ generated_at: "push" });
    expect(qc.getQueryData(DASHBOARD_KEY)).toEqual({ generated_at: "push" });

    cleanup();
    expect(fake.channel.leave).toHaveBeenCalled();
  });

  it("reports connection lifecycle states", () => {
    const qc = new QueryClient();
    const fake = fakeChannel();
    const onStatus = vi.fn();
    const joinSnapshot = { generated_at: "join" };

    hydrateFromChannel(qc, fake.channel as never, { onStatus });

    expect(onStatus).toHaveBeenCalledWith("connecting");
    fake.emitJoinOk({ state: joinSnapshot });
    expect(onStatus).toHaveBeenCalledWith("live");
    expect(qc.getQueryData(DASHBOARD_KEY)).toEqual(joinSnapshot);

    fake.emitError();
    expect(onStatus).toHaveBeenCalledWith("reconnecting");
    expect(qc.getQueryData(DASHBOARD_KEY)).toEqual(joinSnapshot);

    fake.emitClose();
    expect(onStatus).toHaveBeenCalledWith("offline");
    expect(qc.getQueryData(DASHBOARD_KEY)).toEqual(joinSnapshot);
  });
});
