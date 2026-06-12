import { useMemo } from "react";
import type { ColumnDef } from "@tanstack/react-table";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { DataTable } from "@/components/DataTable";
import { StatusBadge } from "@/components/StatusBadge";
import { ElapsedTime } from "@/components/ElapsedTime";
import { useWorkRuns } from "@/features/project/useWorkRuns";
import type { WorkRunListItem } from "@/types/contract";

interface WorkRunHistoryTableProps {
  slug: string;
}

export function WorkRunHistoryTable({ slug }: WorkRunHistoryTableProps) {
  const { data, isFetching, hasNextPage, fetchNextPage, refetch, error } = useWorkRuns(slug, {});

  const rows = useMemo(
    () => data?.pages.flatMap((p) => p.work_runs) ?? [],
    [data],
  );

  const columns = useMemo<ColumnDef<WorkRunListItem, unknown>[]>(
    () => [
      {
        id: "identifier",
        header: "Identifier",
        accessorFn: (row) => row.linear_identifier ?? "—",
        cell: ({ getValue }) => {
          const v = getValue() as string;
          return v === "—" ? (
            <span className="text-muted-foreground">—</span>
          ) : (
            <span className="font-mono">{v}</span>
          );
        },
      },
      {
        id: "type",
        header: "Type",
        accessorKey: "type",
      },
      {
        id: "status",
        header: "Status",
        accessorKey: "status",
        cell: ({ getValue }) => <StatusBadge status={getValue() as string} />,
      },
      {
        id: "pr",
        header: "PR",
        enableSorting: false,
        accessorFn: (row) => row,
        cell: ({ getValue }) => {
          const row = getValue() as WorkRunListItem;
          if (row.github_owner && row.github_repo && row.github_pr_number != null) {
            const url = `https://github.com/${row.github_owner}/${row.github_repo}/pull/${row.github_pr_number}`;
            return (
              <a
                href={url}
                target="_blank"
                rel="noreferrer"
                className="underline underline-offset-2"
              >
                #{row.github_pr_number}
              </a>
            );
          }
          return <span className="text-muted-foreground">—</span>;
        },
      },
      {
        id: "updated",
        header: "Updated",
        accessorKey: "updated_at",
        cell: ({ getValue }) => <ElapsedTime since={getValue() as string} />,
      },
    ],
    [],
  );

  if (error) {
    return (
      <Alert variant="destructive">
        <AlertTitle>Error loading history</AlertTitle>
        <AlertDescription>{error.message}</AlertDescription>
        <div className="mt-2">
          <Button variant="outline" size="sm" onClick={() => void refetch()}>
            Retry
          </Button>
        </div>
      </Alert>
    );
  }

  return (
    <DataTable
      columns={columns}
      data={rows}
      hasNextPage={hasNextPage}
      onLoadMore={() => void fetchNextPage()}
      isLoading={isFetching}
      emptyMessage="No work runs yet."
    />
  );
}
