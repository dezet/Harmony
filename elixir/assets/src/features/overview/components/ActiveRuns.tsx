import { Link } from "react-router-dom";
import { ElapsedTime } from "@/components/ElapsedTime";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { RunningEntry } from "@/types/contract";

export function ActiveRuns({ rows }: { rows: RunningEntry[] }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Active runs</CardTitle>
      </CardHeader>
      <CardContent>
        {rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">No runs in progress.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Issue</TableHead>
                <TableHead>Project</TableHead>
                <TableHead>State</TableHead>
                <TableHead>Turns</TableHead>
                <TableHead>Tokens</TableHead>
                <TableHead>Elapsed</TableHead>
                <TableHead>Last event</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.session_id ?? row.issue_id}>
                  <TableCell className="font-mono">
                    {row.project?.slug ? (
                      <Link
                        to={`/projects/${row.project.slug}/runs/${row.issue_identifier}`}
                        className="underline underline-offset-2 hover:opacity-80"
                      >
                        {row.issue_identifier}
                      </Link>
                    ) : (
                      row.issue_identifier
                    )}
                  </TableCell>
                  <TableCell>{row.project?.slug ?? "—"}</TableCell>
                  <TableCell>{row.state}</TableCell>
                  <TableCell className="font-mono">{row.turn_count}</TableCell>
                  <TableCell className="font-mono">
                    {row.tokens.total_tokens.toLocaleString("en-US")}
                  </TableCell>
                  <TableCell>
                    <ElapsedTime since={row.started_at} />
                  </TableCell>
                  <TableCell className="text-muted-foreground">{row.last_event ?? "—"}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>
    </Card>
  );
}
