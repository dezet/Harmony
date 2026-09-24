import { vi } from "vitest";

// Test double of the phoenix Socket/Channel pair: no WebSocket, every server
// reply is triggered by the test. The join push keeps its receive hooks like
// phoenix does, so a second "ok" models an automatic rejoin after reconnect.

type Handler = (payload: unknown) => void;

export interface FakeChannel {
  topic: string;
  on: (event: string, cb: Handler) => number;
  onError: (cb: () => void) => number;
  onClose: (cb: () => void) => number;
  join: () => FakePush;
  leave: ReturnType<typeof vi.fn>;
  emit: (event: string, payload: unknown) => void;
  reply: (status: "ok" | "error" | "timeout") => void;
  error: () => void;
  close: () => void;
}

export interface FakePush {
  receive: (status: string, cb: (resp: unknown) => void) => FakePush;
}

export interface FakeSocket {
  channel: ReturnType<typeof vi.fn>;
  channels: FakeChannel[];
}

export function makeFakeSocket(): FakeSocket {
  const channels: FakeChannel[] = [];
  return {
    channels,
    channel: vi.fn((topic: string) => {
      const channel = makeFakeChannel(topic);
      channels.push(channel);
      return channel;
    }),
  };
}

function makeFakeChannel(topic: string): FakeChannel {
  const handlers: Record<string, Handler[]> = {};
  const receives: Record<string, ((resp: unknown) => void)[]> = {};
  const errorHandlers: (() => void)[] = [];
  const closeHandlers: (() => void)[] = [];

  const push: FakePush = {
    receive(status, cb) {
      (receives[status] ??= []).push(cb);
      return push;
    },
  };

  return {
    topic,
    on: (event, cb) => {
      (handlers[event] ??= []).push(cb);
      return 0;
    },
    onError: (cb) => {
      errorHandlers.push(cb);
      return 0;
    },
    onClose: (cb) => {
      closeHandlers.push(cb);
      return 0;
    },
    join: () => push,
    leave: vi.fn(() => {
      closeHandlers.forEach((cb) => cb());
      return { receive: () => undefined };
    }),
    emit: (event, payload) => handlers[event]?.forEach((cb) => cb(payload)),
    reply: (status) => receives[status]?.forEach((cb) => cb({})),
    error: () => errorHandlers.forEach((cb) => cb()),
    close: () => closeHandlers.forEach((cb) => cb()),
  };
}
