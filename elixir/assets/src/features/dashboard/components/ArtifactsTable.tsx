import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { ArtifactTableRow } from "@/types/contract";

export function ArtifactsTable({ rows }: { rows: ArtifactTableRow[] }) {
  if (rows.length === 0) return <p className="text-muted-foreground">No artifacts.</p>;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Kind</TableHead>
          <TableHead>Path</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((a, i) => (
          <TableRow key={a.id ?? `${a.kind}-${a.path}-${i}`}>
            <TableCell>{a.kind ?? "—"}</TableCell>
            <TableCell className="max-w-md truncate">{a.path ?? "—"}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
