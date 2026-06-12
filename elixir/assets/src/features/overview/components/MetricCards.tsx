import { Card, CardHeader, CardTitle, CardContent } from "@/components/ui/card";
import type { StatePayload } from "@/types/contract";

function Metric({ label, value }: { label: string; value: number | string }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-sm text-muted-foreground">{label}</CardTitle>
      </CardHeader>
      <CardContent className="text-3xl font-semibold">{value}</CardContent>
    </Card>
  );
}

export function MetricCards({ state }: { state: StatePayload }) {
  const counts = state.counts ?? { running: 0, retrying: 0, blocked: 0 };
  const totalTokens = state.codex_totals?.total_tokens ?? 0;

  return (
    <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
      <Metric label="Running" value={counts.running} />
      <Metric label="Retrying" value={counts.retrying} />
      <Metric label="Blocked" value={counts.blocked} />
      <Metric label="Total tokens" value={totalTokens} />
    </div>
  );
}
