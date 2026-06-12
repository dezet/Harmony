import { useNow } from "@/lib/useNow";
import { elapsedSeconds, formatDuration } from "@/lib/format";

// The 1s clock lives here, in a leaf, so ticking re-renders only this span —
// not the page that renders it (the old DashboardPage re-rendered wholesale).
export function ElapsedTime({ since }: { since: string | null }) {
  const nowMs = useNow();
  const seconds = elapsedSeconds(since, nowMs);
  if (seconds == null) return <span>—</span>;
  return <span className="font-mono text-sm tabular-nums">{formatDuration(seconds)}</span>;
}
