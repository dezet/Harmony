import { useEffect } from "react";
import { Skeleton } from "@/components/ui/skeleton";
import { useDashboard } from "@/features/dashboard/useDashboard";
import { RateLimits } from "@/features/runtime/components/RateLimits";
import { RuntimeCard } from "@/features/runtime/components/RuntimeCard";

export function RuntimePage() {
  const { data, isLoading } = useDashboard();

  useEffect(() => {
    document.title = "Środowisko uruchomieniowe — Harmony";
  }, []);

  if (isLoading && !data) return <Skeleton aria-label="Wczytywanie środowiska" className="h-48 w-full" />;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-title max-[1150px]:text-[26px] max-[600px]:text-[27px]">Środowisko uruchomieniowe</h1>
        <p className="mt-2 text-xs leading-[1.6] text-muted-foreground">
          Sandbox agentów i limity zapytań zgłoszone przez silnik Codex.
        </p>
      </div>

      {data?.runtime?.sandbox ? (
        <RuntimeCard sandbox={data.runtime.sandbox} />
      ) : (
        <p className="text-muted-foreground">Brak informacji o sandboxie.</p>
      )}

      <section className="rounded-[10px] border bg-card p-[23px] max-[600px]:p-[18px]">
        <h2 className="mb-3 text-[17px] font-semibold">Limity zapytań</h2>
        <RateLimits value={data?.rate_limits ?? null} />
      </section>
    </div>
  );
}
