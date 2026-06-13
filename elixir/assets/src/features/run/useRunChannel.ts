import { useEffect } from "react";
import type { QueryClient } from "@tanstack/react-query";
import type { RunDetail, RunStreamItem, RunStreamPage, Tokens } from "@/types/contract";
import { RUN_KEY, RUN_STREAM_KEY } from "@/lib/queryClient";
import { getSocket } from "@/lib/socket";

// ─── Payload shapes (Locked decision 5) ─────────────────────────────────────

interface StatusChangedPayload {
  issue_id: string;
  identifier: string;
  status: string;
  last_error: string | null;
  at: string;
}

interface EventAppendedPayload {
  issue_id: string;
  identifier: string;
  item: RunStreamItem;
}

interface TokensUpdatedPayload {
  issue_id: string;
  identifier: string;
  tokens: Tokens;
  turn_count: number;
  at: string;
}

// ─── Cache patch helpers ─────────────────────────────────────────────────────

function patchStatusChanged(
  queryClient: QueryClient,
  identifier: string,
  payload: StatusChangedPayload,
): void {
  const key = RUN_KEY(identifier);
  const current = queryClient.getQueryData<RunDetail>(key);
  if (!current) return;
  queryClient.setQueryData<RunDetail>(key, {
    ...current,
    status: payload.status,
    last_error: payload.last_error,
    last_event_at: payload.at,
  });
}

function patchTokensUpdated(
  queryClient: QueryClient,
  identifier: string,
  payload: TokensUpdatedPayload,
): void {
  const key = RUN_KEY(identifier);
  const current = queryClient.getQueryData<RunDetail>(key);
  if (!current) return;
  queryClient.setQueryData<RunDetail>(key, {
    ...current,
    tokens: payload.tokens,
    turn_count: payload.turn_count,
    last_event_at: payload.at,
  });
}

interface InfiniteData {
  pages: RunStreamPage[];
  pageParams: unknown[];
}

function appendStreamItem(
  queryClient: QueryClient,
  identifier: string,
  item: RunStreamItem,
): void {
  const key = RUN_STREAM_KEY(identifier);
  const current = queryClient.getQueryData<InfiniteData>(key);

  if (!current || current.pages.length === 0) {
    // Create a synthetic first page
    const syntheticPage: RunStreamPage = {
      items: [item],
      meta: { next_cursor: null, has_live: true },
    };
    queryClient.setQueryData<InfiniteData>(key, {
      pages: [syntheticPage],
      pageParams: [undefined],
    });
    return;
  }

  // Dedupe: skip if item already exists in any page
  for (const page of current.pages) {
    if (page.items.some((i) => i.id === item.id)) return;
  }

  // Append to the last page
  const lastIndex = current.pages.length - 1;
  const updatedPages = current.pages.map((page, idx) => {
    if (idx !== lastIndex) return page;
    return { ...page, items: [...page.items, item] };
  });

  queryClient.setQueryData<InfiniteData>(key, {
    ...current,
    pages: updatedPages,
  });
}

// ─── Hook ────────────────────────────────────────────────────────────────────

/**
 * Joins `observability:run:<issueId>` on the shared app socket and applies
 * granular cache patches for the three run channel events. No-op when issueId
 * is null (run has no live orchestrator entry).
 *
 * @param onConnectionError - Optional callback fired when the channel join
 *   receives an "error" or "timeout" response from the server. Use to surface
 *   a degraded-state notice in the UI (live updates unavailable, REST data
 *   still valid).
 */
export function useRunChannel(
  queryClient: QueryClient,
  issueId: string | null,
  identifier: string,
  onConnectionError?: () => void,
): void {
  useEffect(() => {
    if (!issueId) return;

    const socket = getSocket();
    const channel = socket.channel(`observability:run:${issueId}`, {});

    channel.on("status_changed", (payload: StatusChangedPayload) => {
      patchStatusChanged(queryClient, identifier, payload);
    });

    channel.on("event_appended", (payload: EventAppendedPayload) => {
      appendStreamItem(queryClient, identifier, payload.item);
    });

    channel.on("tokens_updated", (payload: TokensUpdatedPayload) => {
      patchTokensUpdated(queryClient, identifier, payload);
    });

    channel
      .join()
      .receive("error", () => onConnectionError?.())
      .receive("timeout", () => onConnectionError?.());

    return () => {
      channel.leave();
    };
  }, [queryClient, issueId, identifier, onConnectionError]);
}
