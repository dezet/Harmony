import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { ElapsedTime } from "@/components/ElapsedTime";
import type { ProjectSummary } from "@/types/contract";

interface RunningColumnProps {
  rows: ProjectSummary["running"];
}

export function RunningColumn({ rows }: RunningColumnProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Running</CardTitle>
      </CardHeader>
      <CardContent>
        {rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">No runs in progress.</p>
        ) : (
          <ul className="space-y-2">
            {rows.map((row) => (
              <li key={row.issue_id} className="flex flex-col gap-0.5 text-sm">
                <div className="flex items-center gap-2">
                  <span className="font-mono">{row.issue_identifier}</span>
                  <span className="text-muted-foreground">{row.state}</span>
                  <span className="font-mono text-xs text-muted-foreground">
                    {row.turn_count} turns
                  </span>
                  <ElapsedTime since={row.started_at} />
                </div>
                {row.last_event && (
                  <span className="text-xs text-muted-foreground truncate">{row.last_event}</span>
                )}
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}
