import { Link } from "react-router-dom";
import { ElapsedTime } from "@/components/ElapsedTime";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { needsAttention, type AttentionItem } from "@/lib/health";
import type { StatePayload } from "@/types/contract";

const kindLabels: Record<AttentionItem["kind"], string> = {
  blocked: "Zablokowany",
  retry_error: "Ponawianie z błędem",
  sandbox_warning: "Sandbox",
};

export function NeedsAttention({ state }: { state: StatePayload }) {
  const items = needsAttention(state);

  return (
    <Card>
      <CardHeader>
        <CardTitle>
          <h2 className="text-[17px] font-semibold">Wymaga uwagi</h2>
        </CardTitle>
      </CardHeader>
      <CardContent>
        {items.length === 0 ? (
          <p className="text-sm text-muted-foreground">Wszystko w porządku — nic nie wymaga uwagi.</p>
        ) : (
          <ul className="divide-y">
            {items.map((item) => (
              <li key={item.key} className="flex items-center gap-3 py-2 text-sm">
                <Badge variant={item.kind === "sandbox_warning" ? "outline" : "destructive"}>
                  {kindLabels[item.kind]}
                </Badge>
                {item.identifier ? (
                  item.projectSlug ? (
                    <Link
                      to={`/projects/${item.projectSlug}/runs/${item.identifier}`}
                      className="font-mono underline underline-offset-2 hover:opacity-80"
                    >
                      {item.identifier}
                    </Link>
                  ) : (
                    <span className="font-mono">{item.identifier}</span>
                  )
                ) : null}
                {item.projectSlug ? (
                  <span className="text-muted-foreground">{item.projectSlug}</span>
                ) : null}
                <span className="min-w-0 flex-1 truncate" title={item.message}>
                  {item.message}
                </span>
                {item.since ? <ElapsedTime since={item.since} /> : null}
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}
