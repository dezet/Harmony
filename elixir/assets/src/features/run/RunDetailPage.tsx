import { useState, useCallback, useEffect } from "react";
import { Link, useParams } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Skeleton } from "@/components/ui/skeleton";
import { Button } from "@/components/ui/button";
import { StatusBadge } from "@/components/StatusBadge";
import { ApiError } from "@/lib/api";
import { useRunDetail } from "@/features/run/useRunDetail";
import { useRunStream } from "@/features/run/useRunStream";
import { useRunChannel } from "@/features/run/useRunChannel";
import { RunStream } from "@/features/run/components/RunStream";
import { RunRail } from "@/features/run/components/RunRail";

export function RunDetailPage() {
  const { slug, identifier } = useParams<{ slug: string; identifier: string }>();
  const queryClient = useQueryClient();
  const [channelFailed, setChannelFailed] = useState(false);
  const handleConnectionError = useCallback(() => setChannelFailed(true), []);

  const {
    data: detail,
    isLoading: detailLoading,
    error: detailError,
    refetch: detailRefetch,
  } = useRunDetail(identifier!);

  const {
    data: streamData,
    isLoading: streamLoading,
    error: streamError,
    refetch: streamRefetch,
    hasNextPage,
    fetchNextPage,
  } = useRunStream(identifier!);

  useRunChannel(queryClient, detail?.issue_id ?? null, identifier!, handleConnectionError);

  useEffect(() => {
    if (identifier) {
      document.title = `${identifier} — Harmony`;
    }
  }, [identifier]);

  // Loading skeleton
  if (detailLoading && !detail) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-10 w-64" />
        <Skeleton className="h-8 w-48" />
      </div>
    );
  }

  // 404
  if (detailError instanceof ApiError && detailError.status === 404) {
    return (
      <div className="flex flex-col items-center justify-center gap-4 py-24 text-center">
        <h1 className="text-title">Nie znaleziono przebiegu</h1>
        <p className="text-muted-foreground">
          Nie ma przebiegu o identyfikatorze <span className="font-mono">{identifier}</span>.
        </p>
        <Link
          to={`/projects/${slug}`}
          className="text-sm underline underline-offset-2"
        >
          Wróć do projektu
        </Link>
      </div>
    );
  }

  // Other error
  if (detailError) {
    return (
      <Alert variant="destructive">
        <AlertTitle>Nie udało się wczytać przebiegu</AlertTitle>
        <AlertDescription>{detailError.message}</AlertDescription>
        <div className="mt-2">
          <Button variant="outline" size="sm" onClick={() => void detailRefetch()}>
            Spróbuj ponownie
          </Button>
        </div>
      </Alert>
    );
  }

  if (!detail) return null;

  const streamItems = streamData?.pages.flatMap((p) => p.items) ?? [];

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center gap-3">
        <h1 className="font-mono text-title max-[1150px]:text-[26px] max-[600px]:text-[27px]">{detail.identifier}</h1>
        <StatusBadge status={detail.status} />
      </div>

      {/* Two-column layout */}
      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_320px]">
        {/* Left: stream */}
        <div className="space-y-3">
          {channelFailed && (
            <Alert variant="default">
              <AlertTitle>Aktualizacje na żywo są niedostępne</AlertTitle>
              <AlertDescription>
                Widzisz ostatnio wczytane dane; odśwież stronę, aby połączyć się ponownie.
              </AlertDescription>
            </Alert>
          )}
          <RunStream
            items={streamItems}
            isLoading={streamLoading}
            error={streamError as Error | null}
            onRetry={() => void streamRefetch()}
            hasNextPage={hasNextPage}
            onLoadMore={() => void fetchNextPage()}
          />
        </div>

        {/* Right: rail */}
        <div className="lg:sticky lg:top-6 self-start">
          <RunRail detail={detail} />
        </div>
      </div>
    </div>
  );
}
