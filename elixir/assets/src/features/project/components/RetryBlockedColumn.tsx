import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { ElapsedTime } from "@/components/ElapsedTime";
import type { ProjectSummary } from "@/types/contract";

interface RetryBlockedColumnProps {
  retrying: ProjectSummary["retrying"];
  blocked: ProjectSummary["blocked"];
}

export function RetryBlockedColumn({ retrying, blocked }: RetryBlockedColumnProps) {
  const isEmpty = blocked.length === 0 && retrying.length === 0;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Retry &amp; blocked</CardTitle>
      </CardHeader>
      <CardContent>
        {isEmpty ? (
          <p className="text-sm text-muted-foreground">Nothing stuck.</p>
        ) : (
          <ul className="space-y-2">
            {blocked.map((item) => (
              <li key={item.issue_id} className="flex flex-col gap-0.5 text-sm">
                <div className="flex items-center gap-2">
                  <Badge variant="destructive">Blocked</Badge>
                  <span className="font-mono">{item.issue_identifier}</span>
                </div>
                {item.error && (
                  <span className="text-xs text-muted-foreground truncate">{item.error}</span>
                )}
              </li>
            ))}
            {retrying.map((item) => (
              <li key={item.issue_id} className="flex flex-col gap-0.5 text-sm">
                <div className="flex items-center gap-2">
                  <Badge variant="outline">Retry #{item.attempt}</Badge>
                  <span className="font-mono">{item.issue_identifier}</span>
                </div>
                {item.error && (
                  <span className="text-xs text-muted-foreground truncate">{item.error}</span>
                )}
                {item.due_at && (
                  <span className="text-xs text-muted-foreground">
                    due <ElapsedTime since={item.due_at} />
                  </span>
                )}
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}
