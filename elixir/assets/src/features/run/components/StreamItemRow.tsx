import { Badge } from "@/components/ui/badge";
import type { RunStreamItem } from "@/types/contract";

const MAX_MESSAGE_LENGTH = 120;
const MAX_JSON_LENGTH = 120;

function truncate(str: string, max: number): string {
  if (str.length <= max) return str;
  return str.slice(0, max) + "…";
}

function PayloadSummary({ payload }: { payload: Record<string, unknown> | null }) {
  if (!payload) return null;

  // String message
  if (typeof payload.message === "string") {
    return (
      <span
        data-testid="payload-summary"
        className="text-xs text-muted-foreground truncate"
      >
        {truncate(payload.message, MAX_MESSAGE_LENGTH)}
      </span>
    );
  }

  // Non-empty object — show compact JSON
  const keys = Object.keys(payload);
  if (keys.length === 0) return null;

  const full = JSON.stringify(payload);
  const summary = truncate(full, MAX_JSON_LENGTH);

  return (
    <span
      data-testid="payload-summary"
      className="text-xs text-muted-foreground font-mono truncate"
      title={full}
    >
      {summary}
    </span>
  );
}

export function StreamItemRow({ item }: { item: RunStreamItem }) {
  const kindBadgeVariant = item.kind === "live_event" ? "secondary" : "outline";
  const kindLabel = item.kind === "live_event" ? "live" : "event";

  return (
    <li className="flex flex-col gap-0.5 py-1 text-sm border-b border-border last:border-b-0">
      <div className="flex items-center gap-2 flex-wrap">
        <span className="font-mono text-xs text-muted-foreground">{item.at}</span>
        <Badge variant={kindBadgeVariant}>{kindLabel}</Badge>
        <span className="font-mono text-xs">{item.type}</span>
      </div>
      <PayloadSummary payload={item.payload} />
    </li>
  );
}
