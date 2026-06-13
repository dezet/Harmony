import { Socket, type Channel } from "phoenix";
import type { QueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import type { StatePayload } from "@/types/contract";
import { DASHBOARD_KEY } from "@/lib/queryClient";
import type { DashboardConnectionStatus } from "@/lib/dashboardConnection";

export { DASHBOARD_KEY };

function csrfToken(): string | undefined {
  return document.querySelector("meta[name='csrf-token']")?.getAttribute("content") ?? undefined;
}

export function createSocket(): Socket {
  const socket = new Socket("/socket", { params: { token: csrfToken() } });
  socket.connect();
  return socket;
}

// Module-level singleton — one Socket connection for the entire app lifetime.
let _socket: Socket | null = null;

/**
 * Returns the app-wide shared Socket, creating and connecting it on first call.
 * Both the dashboard channel and per-run channels share this single connection.
 */
export function getSocket(): Socket {
  if (!_socket) {
    _socket = createSocket();
  }
  return _socket;
}

interface HydrateFromChannelOptions {
  onStatus?: (status: DashboardConnectionStatus) => void;
}

/**
 * Subscribe a phoenix channel to the dashboard topic and write every snapshot
 * (the join reply and each "state" push) into the React Query cache.
 * Returns a cleanup function that leaves the channel.
 */
export function hydrateFromChannel(
  queryClient: QueryClient,
  channel: Channel,
  options: HydrateFromChannelOptions = {},
): () => void {
  options.onStatus?.("connecting");

  channel.on("state", (payload: StatePayload) => {
    queryClient.setQueryData(DASHBOARD_KEY, payload);
    options.onStatus?.("live");
  });

  channel.onError(() => {
    options.onStatus?.("reconnecting");
  });

  channel.onClose(() => {
    options.onStatus?.("offline");
  });

  channel
    .join()
    .receive("ok", (resp: { state: StatePayload }) => {
      queryClient.setQueryData(DASHBOARD_KEY, resp.state);
      options.onStatus?.("live");
    })
    .receive("error", () => {
      options.onStatus?.("offline");
    })
    .receive("timeout", () => {
      options.onStatus?.("offline");
    });

  return () => {
    channel.leave();
  };
}

/** Open the dashboard channel for the lifetime of the component tree. */
export function useDashboardChannel(
  queryClient: QueryClient,
  onStatus?: (status: DashboardConnectionStatus) => void,
): void {
  useEffect(() => {
    const socket = getSocket();
    const channel = socket.channel("observability:dashboard", {});
    const cleanup = hydrateFromChannel(queryClient, channel, { onStatus });
    return cleanup;
  }, [queryClient, onStatus]);
}
