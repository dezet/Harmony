import { useParams, Link, useSearchParams } from "react-router-dom";
import { useEffect } from "react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Skeleton } from "@/components/ui/skeleton";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useProjectSummary } from "@/features/project/useProjectSummary";
import { WorkTab } from "@/features/project/WorkTab";
import { ConfigurationTab } from "@/features/project/ConfigurationTab";
import { EvidenceTab } from "@/features/project/components/EvidenceTab";
import { ActivityTab } from "@/features/project/components/ActivityTab";
import { projectHealth } from "@/lib/health";
import { ApiError } from "@/lib/api";

type Tab = "work" | "evidence" | "activity" | "configuration";

const VALID_TABS: readonly Tab[] = ["work", "evidence", "activity", "configuration"];

function isValidTab(value: string | null): value is Tab {
  return VALID_TABS.includes(value as Tab);
}

// Health of the agent runs; unrelated to the project identity color.
const healthDotClass: Record<string, string> = {
  healthy: "bg-success",
  retrying: "bg-warning",
  blocked: "bg-destructive",
  idle: "bg-muted-foreground",
};

const healthLabel: Record<string, string> = {
  healthy: "w toku",
  retrying: "ponawia",
  blocked: "zablokowany",
  idle: "bezczynny",
};


export function ProjectWorkspacePage() {
  const { slug } = useParams<{ slug: string }>();
  const [searchParams, setSearchParams] = useSearchParams();
  const tabParam = searchParams.get("tab");
  const activeTab: Tab = isValidTab(tabParam) ? tabParam : "work";

  const { data: summary, isLoading, error, refetch } = useProjectSummary(slug!);

  useEffect(() => {
    if (slug) {
      document.title = `${slug} — Harmony`;
    }
  }, [slug]);

  if (isLoading && !summary) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-10 w-48" />
        <Skeleton className="h-8 w-64" />
        <Skeleton className="h-64 w-full" />
      </div>
    );
  }

  if (error) {
    if (error instanceof ApiError && error.status === 404) {
      return (
        <div className="flex flex-col items-center justify-center gap-4 py-24 text-center">
          <h1 className="text-title">Nie znaleziono projektu</h1>
          <p className="text-muted-foreground">
            Nie ma projektu o slugu <span className="font-mono">{slug}</span>.
          </p>
          <Link to="/projects" className="text-sm underline underline-offset-2">
            Wróć do projektów
          </Link>
        </div>
      );
    }

    return (
      <Alert variant="destructive">
        <AlertTitle>Nie udało się wczytać projektu</AlertTitle>
        <AlertDescription>{error.message}</AlertDescription>
        <div className="mt-2">
          <Button variant="outline" size="sm" onClick={() => void refetch()}>
            Spróbuj ponownie
          </Button>
        </div>
      </Alert>
    );
  }

  if (!summary) return null;

  const health = projectHealth(summary.counts);
  const { running, retrying, blocked } = summary.counts;

  const tabs: { id: Tab; label: string }[] = [
    { id: "work", label: "Praca" },
    { id: "evidence", label: "Dowody" },
    { id: "activity", label: "Aktywność" },
    { id: "configuration", label: "Konfiguracja" },
  ];

  function handleTabChange(id: Tab) {
    if (id === "work") {
      setSearchParams({});
    } else {
      setSearchParams({ tab: id });
    }
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="space-y-1">
        <div className="flex items-center gap-2">
          <span
            className={`inline-block h-2.5 w-2.5 rounded-full ${healthDotClass[health] ?? "bg-muted-foreground"}`}
            aria-hidden="true"
          />
          <h1 className="text-title max-[1150px]:text-[26px] max-[600px]:text-[27px]">
            {summary.project.display_name ?? summary.project.slug}
          </h1>
          <span className="sr-only">{healthLabel[health] ?? health}</span>
        </div>
        <p className="font-mono text-sm text-muted-foreground">
          {summary.project.display_name ? `${summary.project.slug} · ` : ""}w toku: {running} · ponawiane: {retrying} ·
          zablokowane: {blocked}
        </p>
        <Link to={`/?project=${encodeURIComponent(summary.project.slug)}`} className="text-xs text-primary underline-offset-2 hover:underline">
          Sprawy projektu w Centrum spraw
        </Link>
      </div>

      <Tabs value={activeTab} onValueChange={(value) => handleTabChange(value as Tab)}>
        <TabsList>
          {tabs.map((tab) => (
            <TabsTrigger key={tab.id} value={tab.id}>
              {tab.label}
            </TabsTrigger>
          ))}
        </TabsList>

        <TabsContent value="work">
          <WorkTab summary={summary} slug={slug!} />
        </TabsContent>
        <TabsContent value="evidence">
          <EvidenceTab slug={slug!} />
        </TabsContent>
        <TabsContent value="activity">
          <ActivityTab slug={slug!} />
        </TabsContent>
        <TabsContent value="configuration">
          <ConfigurationTab projectId={summary.project.id} slug={slug!} />
        </TabsContent>
      </Tabs>
    </div>
  );
}
