export function elapsedSeconds(iso: string | null, nowMs: number): number | null {
  if (!iso) return null;
  return Math.max(0, Math.floor((nowMs - new Date(iso).getTime()) / 1000));
}

export function secondsUntil(iso: string | null, nowMs: number): number | null {
  if (!iso) return null;
  return Math.max(0, Math.floor((new Date(iso).getTime() - nowMs) / 1000));
}

export function formatDuration(totalSeconds: number): string {
  if (totalSeconds <= 0) return "0s";
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  return [h ? `${h}h` : null, h || m ? `${m}m` : null, `${s}s`].filter(Boolean).join(" ");
}
