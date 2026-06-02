import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { RunningEntry } from "@/types/contract";
import { elapsedSeconds, formatDuration } from "@/lib/format";

export function RunningTable({ rows, nowMs }: { rows: RunningEntry[]; nowMs: number }) {
  if (rows.length === 0) return <p className="text-muted-foreground">No running sessions.</p>;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Issue</TableHead>
          <TableHead>Project</TableHead>
          <TableHead>Turns</TableHead>
          <TableHead>Tokens</TableHead>
          <TableHead>Elapsed</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((r) => {
          const secs = elapsedSeconds(r.started_at, nowMs);
          return (
            <TableRow key={r.issue_id}>
              <TableCell>{r.issue_identifier}</TableCell>
              <TableCell>{r.project?.name ?? "—"}</TableCell>
              <TableCell>{r.turn_count}</TableCell>
              <TableCell>{r.tokens.total_tokens}</TableCell>
              <TableCell>{secs === null ? "—" : formatDuration(secs)}</TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
