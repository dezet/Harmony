import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { RetryEntry } from "@/types/contract";
import { formatDuration, secondsUntil } from "@/lib/format";

export function RetryTable({ rows, nowMs }: { rows: RetryEntry[]; nowMs: number }) {
  if (rows.length === 0) return <p className="text-muted-foreground">No retry queue.</p>;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Issue</TableHead>
          <TableHead>Project</TableHead>
          <TableHead>Attempt</TableHead>
          <TableHead>Due in</TableHead>
          <TableHead>Error</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((r) => {
          const secs = secondsUntil(r.due_at, nowMs);
          return (
            <TableRow key={r.issue_id}>
              <TableCell>{r.issue_identifier}</TableCell>
              <TableCell>{r.project?.name ?? "—"}</TableCell>
              <TableCell>{r.attempt}</TableCell>
              <TableCell>{secs === null ? "—" : formatDuration(secs)}</TableCell>
              <TableCell className="max-w-xs truncate">{r.error ?? "—"}</TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
