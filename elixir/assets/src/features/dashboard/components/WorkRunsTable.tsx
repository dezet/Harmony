import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { DurableWorkRun } from "@/types/contract";

function repoRef(r: DurableWorkRun): string {
  if (!r.github_owner || !r.github_repo) return "—";
  const base = `${r.github_owner}/${r.github_repo}`;
  return r.github_pr_number ? `${base}#${r.github_pr_number}` : base;
}

export function WorkRunsTable({ rows }: { rows: DurableWorkRun[] }) {
  if (rows.length === 0) return <p className="text-muted-foreground">No work runs.</p>;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Type</TableHead>
          <TableHead>Status</TableHead>
          <TableHead>Repo / PR</TableHead>
          <TableHead>Linear</TableHead>
          <TableHead>Dedupe key</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((r) => (
          <TableRow key={r.id}>
            <TableCell>{r.type}</TableCell>
            <TableCell>{r.status}</TableCell>
            <TableCell>{repoRef(r)}</TableCell>
            <TableCell>{r.linear_identifier ?? "—"}</TableCell>
            <TableCell className="max-w-xs truncate">{r.dedupe_key ?? "—"}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
