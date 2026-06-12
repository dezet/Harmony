import { Card, CardHeader, CardTitle, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import type { SandboxRuntime } from "@/types/contract";

export function RuntimeCard({ sandbox }: { sandbox: SandboxRuntime }) {
  const rows: Array<[string, string]> = [
    ["Posture", sandbox.posture ?? "—"],
    [
      "Bubblewrap",
      sandbox.bubblewrap_available === null ? "—" : String(sandbox.bubblewrap_available),
    ],
    ["Thread sandbox", sandbox.thread_sandbox ?? "—"],
    ["Turn sandbox", sandbox.turn_sandbox_type ?? "—"],
  ];

  return (
    <Card>
      <CardHeader>
        <CardTitle>Runtime / sandbox</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <dl className="grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
          {rows.map(([k, v]) => (
            <div key={k} className="contents">
              <dt className="text-muted-foreground">{k}</dt>
              <dd>{v}</dd>
            </div>
          ))}
        </dl>
        {sandbox.warnings.length > 0 ? (
          <div className="flex flex-wrap gap-1">
            {sandbox.warnings.map((w) => (
              <Badge key={w} variant="destructive">
                {w}
              </Badge>
            ))}
          </div>
        ) : null}
      </CardContent>
    </Card>
  );
}
