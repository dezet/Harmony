import { describe, it, expect } from "vitest";
import { formatDuration, elapsedSeconds, secondsUntil } from "@/lib/format";

describe("format", () => {
  it("formats seconds as H/M/S text", () => {
    expect(formatDuration(0)).toBe("0s");
    expect(formatDuration(65)).toBe("1m 5s");
    expect(formatDuration(3661)).toBe("1h 1m 1s");
  });

  it("computes elapsed seconds from an ISO timestamp", () => {
    const now = new Date("2026-06-02T00:01:00Z").getTime();
    expect(elapsedSeconds("2026-06-02T00:00:00Z", now)).toBe(60);
    expect(elapsedSeconds(null, now)).toBeNull();
  });

  it("computes seconds until a future ISO timestamp", () => {
    const now = new Date("2026-06-02T00:00:00Z").getTime();
    expect(secondsUntil("2026-06-02T00:00:30Z", now)).toBe(30);
    expect(secondsUntil("2026-06-01T23:59:00Z", now)).toBe(0);
    expect(secondsUntil(null, now)).toBeNull();
  });
});
