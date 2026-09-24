import { Card, CardHeader, CardTitle, CardContent } from "@/components/ui/card";
import type { StatePayload } from "@/types/contract";

function Metric({ label, value }: { label: string; value: number | string }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-[11px] font-normal text-muted-foreground">{label}</CardTitle>
      </CardHeader>
      <CardContent className="text-[22px] font-semibold tabular-nums">{value}</CardContent>
    </Card>
  );
}

export function MetricCards({ state }: { state: StatePayload }) {
  const counts = state.counts ?? { running: 0, retrying: 0, blocked: 0 };
  const totalTokens = state.codex_totals?.total_tokens ?? 0;

  return (
    <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
      <Metric label="W toku" value={counts.running} />
      <Metric label="Ponawiane" value={counts.retrying} />
      <Metric label="Zablokowane" value={counts.blocked} />
      <Metric label="Tokeny łącznie" value={totalTokens.toLocaleString("pl-PL")} />
    </div>
  );
}
