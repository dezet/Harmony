import { ElapsedTime } from "@/components/ElapsedTime";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { DurableWorkEvent } from "@/types/contract";

export function RecentActivity({ events }: { events: DurableWorkEvent[] }) {
  const recent = [...events]
    // null inserted_at sorts last; equal timestamps keep server order (stable sort).
    .sort((a, b) => (b.inserted_at ?? "").localeCompare(a.inserted_at ?? ""))
    .slice(0, 10);

  if (recent.length === 0) return null;

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Recent activity</CardTitle>
      </CardHeader>
      <CardContent>
        <ul className="divide-y">
          {recent.map((e) => (
            <li key={e.id} className="flex items-center gap-3 py-2 text-sm">
              <span className="font-mono">{e.type}</span>
              {e.inserted_at ? (
                <span className="text-muted-foreground ml-auto">
                  <ElapsedTime since={e.inserted_at} /> ago
                </span>
              ) : null}
            </li>
          ))}
        </ul>
      </CardContent>
    </Card>
  );
}
