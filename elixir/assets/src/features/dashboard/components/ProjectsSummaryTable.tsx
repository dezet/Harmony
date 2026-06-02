import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { ProjectCounts, ProjectRef } from "@/types/contract";

type Row = ProjectRef & { counts: ProjectCounts };

export function ProjectsSummaryTable({ rows }: { rows: Row[] }) {
  if (rows.length === 0) return <p className="text-muted-foreground">No active projects.</p>;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Project</TableHead>
          <TableHead>Running</TableHead>
          <TableHead>Retrying</TableHead>
          <TableHead>Blocked</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((p) => (
          <TableRow key={p.slug ?? p.id ?? p.name ?? ""}>
            <TableCell>{p.name ?? p.slug ?? "—"}</TableCell>
            <TableCell>{p.counts.running}</TableCell>
            <TableCell>{p.counts.retrying}</TableCell>
            <TableCell>{p.counts.blocked}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
