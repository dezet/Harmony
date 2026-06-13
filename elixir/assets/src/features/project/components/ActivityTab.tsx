import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { StreamItemRow } from "@/features/run/components/StreamItemRow";
import { useProjectActivity } from "@/features/project/useProjectActivity";

interface ActivityTabProps {
  slug: string;
}

export function ActivityTab({ slug }: ActivityTabProps) {
  const {
    data,
    isLoading,
    error,
    refetch,
    hasNextPage,
    fetchNextPage,
    isFetchingNextPage,
  } = useProjectActivity(slug);

  if (isLoading) {
    return (
      <div className="space-y-2">
        <Skeleton className="h-8 w-full" />
        <Skeleton className="h-8 w-full" />
        <Skeleton className="h-8 w-full" />
      </div>
    );
  }

  if (error) {
    return (
      <Alert variant="destructive">
        <AlertTitle>Error loading activity</AlertTitle>
        <AlertDescription>{error.message}</AlertDescription>
        <div className="mt-2">
          <Button variant="outline" size="sm" onClick={() => void refetch()}>
            Retry
          </Button>
        </div>
      </Alert>
    );
  }

  const items = data?.pages.flatMap((p) => p.items) ?? [];

  if (items.length === 0) {
    return <p className="text-muted-foreground">No activity yet.</p>;
  }

  return (
    <div className="space-y-2">
      <ul className="divide-y divide-border rounded-md border">
        {items.map((item) => (
          <StreamItemRow key={item.id} item={item} />
        ))}
      </ul>
      {hasNextPage && (
        <div className="flex justify-center pt-2">
          <Button
            variant="outline"
            size="sm"
            onClick={() => void fetchNextPage()}
            disabled={isFetchingNextPage}
          >
            {isFetchingNextPage ? "Loading…" : "Load more"}
          </Button>
        </div>
      )}
    </div>
  );
}
