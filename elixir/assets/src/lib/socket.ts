import { Socket, type Channel } from "phoenix";
import type { QueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import type { StatePayload } from "@/types/contract";
import { DASHBOARD_KEY } from "@/lib/queryClient";

export { DASHBOARD_KEY };

function csrfToken(): string | undefined {
  return document.querySelector("meta[name='csrf-token']")?.getAttribute("content") ?? undefined;
}

export function createSocket(): Socket {
  const socket = new Socket("/socket", { params: { token: csrfToken() } });
  socket.connect();
  return socket;
}

/**
 * Subscribe a phoenix channel to the dashboard topic and write every snapshot
 * (the join reply and each "state" push) into the React Query cache.
 * Returns a cleanup function that leaves the channel.
 */
export function hydrateFromChannel(queryClient: QueryClient, channel: Channel): () => void {
  channel.on("state", (payload: StatePayload) => {
    queryClient.setQueryData(DASHBOARD_KEY, payload);
  });

  channel.join().receive("ok", (resp: { state: StatePayload }) => {
    queryClient.setQueryData(DASHBOARD_KEY, resp.state);
  });

  return () => {
    channel.leave();
  };
}

/** Open the dashboard channel for the lifetime of the component tree. */
export function useDashboardChannel(queryClient: QueryClient): void {
  useEffect(() => {
    const socket = createSocket();
    const channel = socket.channel("observability:dashboard", {});
    const cleanup = hydrateFromChannel(queryClient, channel);
    return () => {
      cleanup();
      socket.disconnect();
    };
  }, [queryClient]);
}
