import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { BlockedEntry } from "@/types/contract";

export function BlockedTable({ rows }: { rows: BlockedEntry[] }) {
  if (rows.length === 0) return <p className="text-muted-foreground">No blocked sessions.</p>;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Issue</TableHead>
          <TableHead>Project</TableHead>
          <TableHead>State</TableHead>
          <TableHead>Error</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((r) => (
          <TableRow key={r.issue_id}>
            <TableCell>{r.issue_identifier}</TableCell>
            <TableCell>{r.project?.name ?? "—"}</TableCell>
            <TableCell>{r.state}</TableCell>
            <TableCell className="max-w-xs truncate">{r.error ?? "—"}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
