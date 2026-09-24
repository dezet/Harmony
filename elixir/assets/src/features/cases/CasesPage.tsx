import { useCallback, useEffect, useMemo, useSyncExternalStore, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { Dialog } from "@base-ui/react/dialog";
import { Clock, SlidersHorizontal, WifiOff, X } from "lucide-react";
import { Button, buttonVariants } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { ApiError } from "@/lib/api";
import { cn } from "@/lib/utils";
import { CaseDetail } from "@/features/cases/CaseDetail";
import { CaseList } from "@/features/cases/CaseList";
import { CaseStats } from "@/features/cases/CaseStats";
import { CaseToolbar } from "@/features/cases/CaseToolbar";
import { useCaseFilters, type CaseTab } from "@/features/cases/useCaseFilters";
import { useCheckNow, useRuleSchedule, type CheckTone } from "@/features/cases/useCaseChecks";
import { useCases } from "@/features/cases/useCases";
import { useIntakeChannel } from "@/features/cases/useIntakeChannel";
import { useProjects } from "@/features/projects/useProjects";

// Case Center (spec §4.3–4.4), list view. Every piece of case data comes from
// the T19 hooks; the URL holds the reproducible state. Desktop shows the list
// with the detail panel of the selected case; a phone opens the detail as a
// dialog only after a tap. The Kanban board is a separate screen (T23).

const DESCRIPTION = "Wiesz, co się dzieje. Widzisz, co zrobić dalej.";

const actionButton =
  "h-auto min-h-[35px] gap-[7px] rounded-[7px] px-3 py-[9px] text-[11px] font-[550] leading-[1.3] max-[600px]:flex-1 [&_svg:not([class*='size-'])]:size-3.5";

const toneClass: Record<CheckTone, string> = {
  success: "text-success",
  warning: "text-warning",
  error: "text-destructive",
};

function subscribeOnline(listener: () => void): () => void {
  window.addEventListener("online", listener);
  window.addEventListener("offline", listener);
  return () => {
    window.removeEventListener("online", listener);
    window.removeEventListener("offline", listener);
  };
}

function useBrowserOnline(): boolean {
  return useSyncExternalStore(subscribeOnline, () => navigator.onLine, () => true);
}

const DESKTOP_QUERY = "(min-width: 601px)";

function subscribeDesktop(listener: () => void): () => void {
  const media = window.matchMedia(DESKTOP_QUERY);
  media.addEventListener("change", listener);
  return () => media.removeEventListener("change", listener);
}

function useIsDesktop(): boolean {
  return useSyncExternalStore(subscribeDesktop, () => window.matchMedia(DESKTOP_QUERY).matches, () => true);
}

function ProjectNotFound({ slug }: { slug: string }) {
  return (
    <div>
      <h1 className="text-title">Nie znaleziono projektu</h1>
      <div className="mt-2 grid gap-2 text-xs leading-[1.6] text-muted-foreground">
        <p>Projekt „{slug}” nie istnieje.</p>
        <p className="flex flex-wrap gap-4">
          <Link className="text-primary underline underline-offset-4" to="/projects">
            Wszystkie projekty
          </Link>
          <Link className="text-primary underline underline-offset-4" to="/">
            Centrum spraw
          </Link>
        </p>
      </div>
    </div>
  );
}

function EmptyState({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="grid justify-items-center gap-2 px-6 py-10 text-center text-xs leading-[1.8] text-muted-foreground">
      <p className="font-semibold text-foreground">{title}</p>
      {children}
    </div>
  );
}

function KanbanPending({ onList }: { onList: () => void }) {
  return (
    <section
      aria-label="Kanban spraw"
      className="grid justify-items-center gap-3 rounded-[11px] border bg-card px-6 py-10 text-center text-xs leading-[1.8] text-muted-foreground"
    >
      <p>Tablica Kanban jest przygotowywana. Filtry i wyszukiwanie zostaną zachowane.</p>
      <Button variant="outline" size="sm" onClick={onList}>
        Pokaż listę
      </Button>
    </section>
  );
}

function DetailPanel({ caseRef, tab, onTabChange }: { caseRef: string | null; tab: CaseTab; onTabChange: (tab: CaseTab) => void }) {
  return (
    <section aria-label="Szczegóły sprawy" className="min-w-0 px-[26px] py-[23px] max-[1150px]:p-5 min-[1600px]:px-8 min-[1600px]:py-7">
      {caseRef ? (
        <CaseDetail key={caseRef} caseRef={caseRef} tab={tab} onTabChange={onTabChange} showOfflineNotice={false} />
      ) : (
        <p className="py-10 text-center text-xs text-muted-foreground">Wybierz sprawę z listy, aby zobaczyć analizę.</p>
      )}
    </section>
  );
}

interface DetailDialogProps {
  caseRef: string | null;
  projectName: string | undefined;
  tab: CaseTab;
  onTabChange: (tab: CaseTab) => void;
  onClose: () => void;
}

function DetailDialog({ caseRef, projectName, tab, onTabChange, onClose }: DetailDialogProps) {
  return (
    <Dialog.Root open={caseRef !== null} onOpenChange={(open) => (open ? undefined : onClose())}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-40 bg-[#11131e88] backdrop-blur-[3px] transition-opacity duration-200 data-ending-style:opacity-0 data-starting-style:opacity-0 motion-reduce:transition-none" />
        <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 flex max-h-[90vh] w-[min(730px,calc(100vw-30px))] -translate-x-1/2 -translate-y-1/2 flex-col overflow-hidden rounded-[13px] border bg-card text-foreground shadow-[0_25px_100px_#0005] outline-none transition-opacity duration-200 data-ending-style:opacity-0 data-starting-style:opacity-0 motion-reduce:transition-none">
          <div className="flex shrink-0 items-center justify-between border-b px-5 py-3 text-[11px] text-muted-foreground">
            <p>
              <Dialog.Title render={<span />} className="font-normal">
                Szczegóły sprawy
              </Dialog.Title>
              {projectName ? <span> · {projectName}</span> : null}
            </p>
            <Dialog.Close
              aria-label="Zamknij szczegóły"
              className="inline-flex rounded-[5px] p-[7px] text-foreground outline-none hover:bg-muted focus-visible:ring-2 focus-visible:ring-ring/50"
            >
              <X aria-hidden className="size-4" strokeWidth={1.6} />
            </Dialog.Close>
          </div>
          <div className="overflow-y-auto p-5">
            {caseRef ? <CaseDetail key={caseRef} caseRef={caseRef} tab={tab} onTabChange={onTabChange} /> : null}
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

export function CasesPage() {
  const { state, listFilters, statsFilters, setFilter, setQuery, setView, selectCase, setTab, clearFilters } =
    useCaseFilters();
  const projects = useProjects();
  const list = useCases(listFilters);
  const stats = useCases(statsFilters);
  const channel = useIntakeChannel();
  const browserOnline = useBrowserOnline();
  const isDesktop = useIsDesktop();

  const slug = state.project;
  const project = slug ? projects.data?.find((entry) => entry.slug === slug) : undefined;
  const projectMissing =
    Boolean(slug) &&
    ((projects.isSuccess && !project) || (list.error instanceof ApiError && list.error.status === 404));

  const rules = useRuleSchedule(project?.id, !slug || Boolean(project));
  const checkNow = useCheckNow();

  const offline = !browserOnline || channel === "offline" || channel === "reconnecting";
  const title = slug ? (project ? project.display_name || project.slug : null) : "Centrum spraw";

  useEffect(() => {
    document.title = `${title ?? "Centrum spraw"} — Harmony`;
  }, [title]);

  const items = useMemo(() => list.data?.pages.flatMap((page) => page.items) ?? [], [list.data]);
  const firstPage = list.data?.pages[0];

  // A selection outside the new result is dropped once the whole result is known.
  const { caseRef } = state;
  const resultKnown = list.isSuccess && !list.hasNextPage && !list.isFetching;
  useEffect(() => {
    if (caseRef && resultKnown && !items.some((item) => item.ref === caseRef)) {
      selectCase(null, { replace: true });
    }
  }, [caseRef, resultKnown, items, selectCase]);

  // Desktop highlights the first result when the URL selects nothing; phones
  // never open anything by themselves.
  const selectedRef = caseRef ?? (isDesktop ? (items[0]?.ref ?? null) : null);

  const onSelect = useCallback((ref: string) => selectCase(ref), [selectCase]);
  const onCloseDialog = useCallback(() => selectCase(null, { replace: true }), [selectCase]);

  if (slug && projectMissing) return <ProjectNotFound slug={slug} />;

  const filtered = state.filter !== "all" || state.q !== "";
  const empty = filtered ? (
    <EmptyState title="Nie ma spraw pasujących do filtrów.">
      <Button variant="outline" size="sm" onClick={clearFilters}>
        Wyczyść filtry
      </Button>
    </EmptyState>
  ) : rules.schedule?.kind === "none" ? (
    <EmptyState title="Brak aktywnych reguł Jira">
      <p>Harmony nie sprawdza jeszcze zgłoszeń w tym zakresie. Utwórz i aktywuj regułę, aby wykrywać nowe sprawy.</p>
      <Link to="/automations" className={cn(buttonVariants({ variant: "outline", size: "sm" }))}>
        Skonfiguruj reguły
      </Link>
    </EmptyState>
  ) : (
    <EmptyState title="Brak spraw">
      <p>Nowe zgłoszenia pojawią się tutaj po kolejnym sprawdzeniu reguł Jira.</p>
    </EmptyState>
  );

  const checkDisabled = offline || checkNow.isPending || (Boolean(slug) && !project);

  return (
    <div>
      <div className="mb-[23px] flex items-center justify-between gap-[18px] max-[850px]:items-start max-[600px]:mb-[18px] max-[600px]:flex-wrap max-[600px]:gap-2.5">
        <div className="min-w-0">
          {title === null ? (
            <Skeleton className="h-9 w-64" />
          ) : (
            <h1 className="text-title max-[1150px]:text-[26px] max-[600px]:text-[27px]">{title}</h1>
          )}
          <p className="mt-2 text-xs leading-[1.6] text-muted-foreground max-[600px]:text-[11px]">{DESCRIPTION}</p>
          {project ? (
            <Link
              className="mt-1 inline-block text-xs text-primary underline underline-offset-4"
              to={`/projects/${encodeURIComponent(project.slug)}`}
            >
              Praca agentów i ustawienia
            </Link>
          ) : null}
        </div>
        <div className="flex shrink-0 gap-2 max-[600px]:w-full">
          <Link to="/automations" className={cn(buttonVariants({ variant: "outline" }), actionButton, "bg-card")}>
            <SlidersHorizontal aria-hidden strokeWidth={1.6} />
            Reguły Jira
          </Link>
          <Button
            className={actionButton}
            disabled={checkDisabled}
            onClick={() => checkNow.mutate(project?.id)}
          >
            <Clock aria-hidden strokeWidth={1.6} />
            {checkNow.isPending ? "Kolejkowanie…" : "Sprawdź teraz"}
          </Button>
        </div>
      </div>

      <p
        role="status"
        aria-live="polite"
        aria-label="Wynik sprawdzenia"
        className={cn(
          "text-[11px]",
          checkNow.data ? toneClass[checkNow.data.tone] : "text-muted-foreground",
          checkNow.data || checkNow.isPending ? "mb-3" : null,
        )}
      >
        {checkNow.isPending ? "Kolejkowanie sprawdzenia reguł Jira…" : (checkNow.data?.message ?? "")}
      </p>

      {offline ? (
        <p
          role="alert"
          className="mb-3 flex items-center gap-2 rounded-[7px] border border-warning/30 bg-warning-surface px-3 py-2 text-[11px] text-warning"
        >
          <WifiOff aria-hidden className="size-3.5 shrink-0" strokeWidth={1.6} />
          Brak połączenia z serwerem. Pokazujemy ostatnio pobrane dane; akcje są wyłączone do czasu połączenia.
        </p>
      ) : null}

      <CaseStats
        counts={stats.data?.pages[0]?.counts}
        countsError={stats.isError && !stats.data}
        schedule={rules.schedule}
        scheduleError={rules.isError}
      />

      <CaseToolbar
        filter={state.filter}
        counts={firstPage?.counts}
        q={state.q}
        view={state.view}
        onFilter={setFilter}
        onQuery={setQuery}
        onView={setView}
      />

      {state.view === "kanban" ? (
        <KanbanPending onList={() => setView("list")} />
      ) : (
        <div
          className={
            isDesktop
              ? "grid min-h-[548px] grid-cols-[minmax(270px,0.82fr)_minmax(0,1.3fr)] overflow-hidden rounded-[11px] border bg-card shadow-[0_1px_2px_#20242f0a] max-[1150px]:grid-cols-[minmax(235px,0.85fr)_minmax(0,1.3fr)] max-[850px]:grid-cols-[minmax(240px,0.8fr)_minmax(0,1.2fr)] min-[1600px]:grid-cols-[minmax(350px,0.8fr)_minmax(0,1.4fr)]"
              : undefined
          }
        >
          <CaseList
            className={isDesktop ? "rounded-none border-0 border-r shadow-none" : undefined}
            status={list.data ? "success" : list.isError ? "error" : "pending"}
            items={items}
            total={firstPage?.meta.total}
            selectedRef={selectedRef}
            refreshFailed={list.isRefetchError}
            hasNextPage={list.hasNextPage}
            isFetchingNextPage={list.isFetchingNextPage}
            nextPageFailed={list.isFetchNextPageError}
            empty={empty}
            onSelect={onSelect}
            onLoadMore={() => void list.fetchNextPage()}
            onRetry={() => void list.refetch()}
          />
          {isDesktop ? <DetailPanel caseRef={selectedRef} tab={state.tab} onTabChange={setTab} /> : null}
        </div>
      )}

      {isDesktop ? null : (
        <DetailDialog
          caseRef={caseRef}
          projectName={items.find((item) => item.ref === caseRef)?.project.name}
          tab={state.tab}
          onTabChange={setTab}
          onClose={onCloseDialog}
        />
      )}
    </div>
  );
}
