import { useEffect } from "react";
import { Skeleton } from "@/components/ui/skeleton";
import { useDashboard } from "@/features/dashboard/useDashboard";
import { RateLimits } from "@/features/runtime/components/RateLimits";
import { RuntimeCard } from "@/features/runtime/components/RuntimeCard";

export function RuntimePage() {
  const { data, isLoading } = useDashboard();

  useEffect(() => {
    document.title = "Runtime — Harmony";
  }, []);

  if (isLoading && !data) return <Skeleton className="h-48 w-full" />;

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Runtime</h1>

      {data?.runtime?.sandbox ? (
        <RuntimeCard sandbox={data.runtime.sandbox} />
      ) : (
        <p className="text-muted-foreground">No sandbox info reported.</p>
      )}

      <section>
        <h2 className="mb-2 text-lg font-medium">Rate limits</h2>
        <RateLimits value={data?.rate_limits ?? null} />
      </section>
    </div>
  );
}
