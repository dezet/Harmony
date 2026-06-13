import { useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Skeleton } from "@/components/ui/skeleton";
import { StreamItemRow } from "@/features/run/components/StreamItemRow";
import type { RunStreamItem } from "@/types/contract";

type FilterMode = "all" | "events";

interface RunStreamProps {
  items: RunStreamItem[];
  isLoading: boolean;
  error: Error | null;
  onRetry: () => void;
  hasNextPage: boolean;
  onLoadMore: () => void;
}

export function RunStream({
  items,
  isLoading,
  error,
  onRetry,
  hasNextPage,
  onLoadMore,
}: RunStreamProps) {
  const [filter, setFilter] = useState<FilterMode>("all");

  const hasWorkEvents = items.some((i) => i.kind === "work_event");
  const hasLiveEvents = items.some((i) => i.kind === "live_event");
  const hasMixedKinds = hasWorkEvents && hasLiveEvents;

  const visibleItems =
    filter === "events" ? items.filter((i) => i.kind === "work_event") : items;

  return (
    <Card>
      <CardHeader>
        <div className="flex items-center justify-between gap-2 flex-wrap">
          <CardTitle>Stream</CardTitle>
          {hasMixedKinds && (
            <div className="flex items-center gap-1">
              <Button
                variant={filter === "all" ? "secondary" : "outline"}
                size="xs"
                onClick={() => setFilter("all")}
              >
                All
              </Button>
              <Button
                variant={filter === "events" ? "secondary" : "outline"}
                size="xs"
                onClick={() => setFilter("events")}
              >
                Events
              </Button>
            </div>
          )}
        </div>
      </CardHeader>
      <CardContent className="space-y-2">
        {error && (
          <Alert variant="destructive">
            <AlertDescription className="flex items-center justify-between gap-2">
              <span>{error.message}</span>
              <Button variant="outline" size="xs" onClick={onRetry}>
                Retry
              </Button>
            </AlertDescription>
          </Alert>
        )}

        {isLoading && items.length === 0 ? (
          <div className="space-y-2">
            <Skeleton className="h-8 w-full" />
            <Skeleton className="h-8 w-full" />
            <Skeleton className="h-8 w-3/4" />
          </div>
        ) : visibleItems.length === 0 && !error ? (
          <p className="text-sm text-muted-foreground">No events yet.</p>
        ) : (
          <>
            <ul className="divide-y divide-border">
              {visibleItems.map((item) => (
                <StreamItemRow key={item.id} item={item} />
              ))}
            </ul>
            {hasNextPage && (
              <div className="flex justify-center pt-2">
                <Button variant="outline" size="sm" onClick={onLoadMore}>
                  Load more
                </Button>
              </div>
            )}
          </>
        )}
      </CardContent>
    </Card>
  );
}
