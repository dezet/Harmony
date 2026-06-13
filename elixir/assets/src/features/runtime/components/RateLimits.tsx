import type { RateLimitBucket, RateLimitsPayload } from "@/types/contract";
import { formatDuration, secondsUntil } from "@/lib/format";
import { useNow } from "@/lib/useNow";

const KNOWN_BUCKET_KEYS = ["primary", "secondary", "credits"] as const;
type KnownBucketKey = (typeof KNOWN_BUCKET_KEYS)[number];

function ResetLabel({
  bucket,
}: {
  bucket: RateLimitBucket;
}) {
  const nowMs = useNow();

  if (
    typeof bucket.reset_in_ms === "number" &&
    bucket.reset_in_ms > 0
  ) {
    const secs = Math.round(bucket.reset_in_ms / 1000);
    return (
      <span className="text-xs text-muted-foreground ml-2">
        resets in {formatDuration(secs)}
      </span>
    );
  }
  if (typeof bucket.reset_at === "string") {
    const secs = secondsUntil(bucket.reset_at, nowMs);
    if (secs != null && secs > 0) {
      return (
        <span className="text-xs text-muted-foreground ml-2">
          resets in {formatDuration(secs)}
        </span>
      );
    }
  }
  return null;
}

function BucketRow({
  name,
  bucket,
}: {
  name: string;
  bucket: RateLimitBucket;
}) {
  const hasProgress =
    typeof bucket.used === "number" && typeof bucket.limit === "number";

  if (hasProgress) {
    const pct = Math.min(100, (bucket.used! / bucket.limit!) * 100);
    return (
      <div className="space-y-1">
        <div className="flex items-center justify-between text-sm">
          <span className="capitalize text-muted-foreground">{name}</span>
          <span>
            {bucket.used} / {bucket.limit}
            <ResetLabel bucket={bucket} />
          </span>
        </div>
        <div
          role="progressbar"
          aria-label={`${name} usage`}
          aria-valuenow={bucket.used}
          aria-valuemin={0}
          aria-valuemax={bucket.limit}
          className="h-2 w-full rounded-full bg-muted overflow-hidden"
        >
          <div
            className="h-full rounded-full bg-primary transition-all"
            style={{ width: `${pct}%` }}
          />
        </div>
      </div>
    );
  }

  // No used/limit — render remaining bucket entries as key-value list
  const entries = Object.entries(bucket).filter(
    ([k]) => k !== "used" && k !== "limit" && k !== "reset_at" && k !== "reset_in_ms",
  );
  return (
    <div>
      <span className="capitalize text-sm text-muted-foreground">{name}</span>
      <dl className="mt-1 grid grid-cols-2 gap-x-4 gap-y-0.5 text-sm">
        {entries.map(([k, v]) => (
          <div key={k} className="contents">
            <dt className="text-muted-foreground">{k}</dt>
            <dd>{String(v ?? "—")}</dd>
          </div>
        ))}
      </dl>
    </div>
  );
}

function ScalarKeyValueList({
  entries,
}: {
  entries: Array<[string, unknown]>;
}) {
  return (
    <dl className="grid grid-cols-2 gap-x-4 gap-y-0.5 text-sm">
      {entries.map(([k, v]) => (
        <div key={k} className="contents">
          <dt className="text-muted-foreground">{k}</dt>
          <dd>{String(v ?? "—")}</dd>
        </div>
      ))}
    </dl>
  );
}

export function RateLimits({
  value,
}: {
  value: RateLimitsPayload | null | undefined;
}) {
  // null / undefined / empty object → empty state
  if (!value || Object.keys(value).length === 0) {
    return <p className="text-muted-foreground">No rate limit data.</p>;
  }

  const header = value.limit_name ?? value.limit_id ?? null;

  // Collect known buckets that are objects
  const buckets: Array<[KnownBucketKey, RateLimitBucket]> = [];
  for (const key of KNOWN_BUCKET_KEYS) {
    const bucket = value[key];
    if (bucket != null && typeof bucket === "object" && !Array.isArray(bucket)) {
      buckets.push([key, bucket as RateLimitBucket]);
    }
  }

  // Collect fallback scalar top-level keys (not limit_id/limit_name/known buckets, not objects)
  const SKIP_SCALAR_KEYS = new Set([
    "limit_id",
    "limit_name",
    ...KNOWN_BUCKET_KEYS,
  ]);
  const scalarEntries = Object.entries(value).filter(
    ([k, v]) => !SKIP_SCALAR_KEYS.has(k) && (v === null || typeof v !== "object"),
  );

  return (
    <div className="space-y-4">
      {header && (
        <p className="text-sm text-muted-foreground">
          Limit: <span className="font-medium text-foreground">{header}</span>
        </p>
      )}

      {buckets.length > 0 && (
        <div className="space-y-3">
          {buckets.map(([name, bucket]) => (
            <BucketRow key={name} name={name} bucket={bucket} />
          ))}
        </div>
      )}

      {scalarEntries.length > 0 && (
        <ScalarKeyValueList entries={scalarEntries} />
      )}
    </div>
  );
}
