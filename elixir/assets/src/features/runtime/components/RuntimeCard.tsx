import { Card, CardHeader, CardTitle, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import type { SandboxRuntime } from "@/types/contract";

export function RuntimeCard({ sandbox }: { sandbox: SandboxRuntime }) {
  const rows: Array<[string, string]> = [
    ["Tryb", sandbox.posture ?? "—"],
    [
      "Bubblewrap dostępny",
      sandbox.bubblewrap_available === null ? "—" : sandbox.bubblewrap_available ? "tak" : "nie",
    ],
    ["Sandbox wątku", sandbox.thread_sandbox ?? "—"],
    ["Sandbox tury", sandbox.turn_sandbox_type ?? "—"],
  ];

  return (
    <Card>
      <CardHeader>
        <CardTitle>
          <h2 className="text-[17px] font-semibold">Sandbox agentów</h2>
        </CardTitle>
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
