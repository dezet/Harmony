import { useEffect, useSyncExternalStore } from "react";
import { useQueryClient, type Query, type QueryClient, type QueryKey } from "@tanstack/react-query";
import type { Channel } from "phoenix";
import { getSocket } from "@/lib/socket";
import { INTAKE_QUERY_ROOTS } from "@/lib/queryClient";
import type { IntakeChangedPayload } from "@/types/contract";

// Case Center realtime (spec §11.4). One `intake:workspace` channel on the
// app-wide socket, shared by every mounted consumer and left with the last one.
// A `changed` push only names what changed; the matching queries are
// invalidated in a 250 ms debounce and refetched over REST. After a rejoin the
// active intake queries are refetched, and while the channel is down a 30 s
// refetch runs, but only when the page is visible.

export type IntakeChannelStatus = "connecting" | "live" | "reconnecting" | "offline";

export const INTAKE_TOPIC = "intake:workspace";
export const INVALIDATION_DEBOUNCE_MS = 250;
// A continuous stream of events still flushes at least this often.
export const INVALIDATION_MAX_WAIT_MS = 1_000;
export const FALLBACK_REFETCH_MS = 30_000;

type Timer = ReturnType<typeof setTimeout>;

interface Subscription {
  channel: Channel;
  clients: Map<QueryClient, number>;
  pending: Map<string, QueryKey>;
  debounce: Timer | null;
  maxWait: Timer | null;
  fallback: ReturnType<typeof setInterval> | null;
  joined: boolean;
  closed: boolean;
  onVisibility: () => void;
}

let current: Subscription | null = null;
let status: IntakeChannelStatus = "connecting";
const statusListeners = new Set<() => void>();

/** Query keys a `changed` push invalidates; `["cases"]` covers every list filter. */
export function invalidationKeys(payload: IntakeChangedPayload): QueryKey[] {
  const keys: QueryKey[] = [["cases"]];

  if (payload.case_ref) keys.push(["case", payload.case_ref], ["case-events", payload.case_ref]);
  if (payload.rule_id) keys.push(["automations"], ["automation", payload.rule_id]);
  if (!payload.case_ref && !payload.rule_id) keys.push(["automations"], ["integrations"]);

  return keys;
}

/**
 * Keeps the shared `intake:workspace` subscription open while the component is
 * mounted and returns the channel state.
 */
export function useIntakeChannel(): IntakeChannelStatus {
  const queryClient = useQueryClient();

  useEffect(() => acquire(queryClient), [queryClient]);

  return useSyncExternalStore(subscribeStatus, readStatus, readStatus);
}

function acquire(queryClient: QueryClient): () => void {
  const subscription = current ?? open();
  subscription.clients.set(queryClient, (subscription.clients.get(queryClient) ?? 0) + 1);

  return () => release(subscription, queryClient);
}

function release(subscription: Subscription, queryClient: QueryClient): void {
  const count = (subscription.clients.get(queryClient) ?? 1) - 1;
  if (count > 0) {
    subscription.clients.set(queryClient, count);
    return;
  }

  subscription.clients.delete(queryClient);
  if (subscription.clients.size === 0) close(subscription);
}

function open(): Subscription {
  const channel = getSocket().channel(INTAKE_TOPIC, {});
  const subscription: Subscription = {
    channel,
    clients: new Map(),
    pending: new Map(),
    debounce: null,
    maxWait: null,
    fallback: null,
    joined: false,
    closed: false,
    onVisibility: () => updateFallback(subscription),
  };
  current = subscription;

  channel.on("changed", (payload: unknown) => {
    if (isChangedPayload(payload)) schedule(subscription, payload);
  });
  channel.onError(() => setStatus(subscription, "reconnecting"));
  channel.onClose(() => setStatus(subscription, "offline"));
  channel
    .join()
    .receive("ok", () => {
      const rejoined = subscription.joined;
      subscription.joined = true;
      setStatus(subscription, "live");
      if (rejoined) refetchActive(subscription);
    })
    .receive("error", () => setStatus(subscription, "offline"))
    .receive("timeout", () => setStatus(subscription, "offline"));

  document.addEventListener("visibilitychange", subscription.onVisibility);
  setStatus(subscription, "connecting");
  return subscription;
}

function close(subscription: Subscription): void {
  subscription.closed = true;
  clearTimer(subscription.debounce);
  clearTimer(subscription.maxWait);
  if (subscription.fallback) clearInterval(subscription.fallback);
  subscription.debounce = null;
  subscription.maxWait = null;
  subscription.fallback = null;
  subscription.pending.clear();
  document.removeEventListener("visibilitychange", subscription.onVisibility);
  subscription.channel.leave();

  if (current === subscription) current = null;
  publishStatus("connecting");
}

function schedule(subscription: Subscription, payload: IntakeChangedPayload): void {
  for (const key of invalidationKeys(payload)) subscription.pending.set(JSON.stringify(key), key);

  clearTimer(subscription.debounce);
  subscription.debounce = setTimeout(() => flush(subscription), INVALIDATION_DEBOUNCE_MS);
  subscription.maxWait ??= setTimeout(() => flush(subscription), INVALIDATION_MAX_WAIT_MS);
}

function flush(subscription: Subscription): void {
  clearTimer(subscription.debounce);
  clearTimer(subscription.maxWait);
  subscription.debounce = null;
  subscription.maxWait = null;

  const keys = [...subscription.pending.values()];
  subscription.pending.clear();
  if (subscription.closed) return;

  for (const queryClient of subscription.clients.keys()) {
    for (const queryKey of keys) void queryClient.invalidateQueries({ queryKey });
  }
}

function refetchActive(subscription: Subscription): void {
  if (subscription.closed) return;

  for (const queryClient of subscription.clients.keys()) {
    void queryClient.refetchQueries({ type: "active", predicate: isIntakeQuery });
  }
}

function setStatus(subscription: Subscription, next: IntakeChannelStatus): void {
  if (subscription.closed) return;
  publishStatus(next);
  updateFallback(subscription);
}

// Polling is a fallback only: never next to a working channel, never for a
// hidden page.
function updateFallback(subscription: Subscription): void {
  const needed = !subscription.closed && status !== "live" && document.visibilityState === "visible";

  if (needed && !subscription.fallback) {
    subscription.fallback = setInterval(() => refetchActive(subscription), FALLBACK_REFETCH_MS);
  } else if (!needed && subscription.fallback) {
    clearInterval(subscription.fallback);
    subscription.fallback = null;
  }
}

function isIntakeQuery(query: Query): boolean {
  const root = query.queryKey[0];
  return typeof root === "string" && INTAKE_QUERY_ROOTS.includes(root);
}

function isChangedPayload(payload: unknown): payload is IntakeChangedPayload {
  if (typeof payload !== "object" || payload === null) return false;
  const value = payload as Record<string, unknown>;
  return (
    optionalString(value.project_id) &&
    optionalString(value.case_ref) &&
    optionalString(value.rule_id) &&
    typeof value.revision === "number"
  );
}

function optionalString(value: unknown): boolean {
  return value === null || value === undefined || typeof value === "string";
}

function clearTimer(timer: Timer | null): void {
  if (timer) clearTimeout(timer);
}

function publishStatus(next: IntakeChannelStatus): void {
  if (status === next) return;
  status = next;
  statusListeners.forEach((listener) => listener());
}

function subscribeStatus(listener: () => void): () => void {
  statusListeners.add(listener);
  return () => statusListeners.delete(listener);
}

function readStatus(): IntakeChannelStatus {
  return status;
}
