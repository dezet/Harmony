import { useId } from "react";
import { Inbox, Search, Workflow, type LucideIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import {
  MAX_SEARCH_LENGTH,
  useSearchDraft,
  type CaseView,
} from "@/features/cases/useCaseFilters";
import type { CaseCounts, CaseListFilter } from "@/types/contract";

// Filters, search and view switch of layout A. Filter badges follow project
// and search but not the active filter (spec §4.4).

const FILTERS: { id: CaseListFilter; label: string; count: keyof CaseCounts }[] = [
  { id: "all", label: "Wszystkie", count: "all" },
  { id: "decision", label: "Do decyzji", count: "decision" },
  { id: "analysis", label: "W analizie", count: "analysis" },
  { id: "done", label: "Zakończone", count: "done" },
];

const VIEWS: { id: CaseView; label: string; icon: LucideIcon }[] = [
  { id: "list", label: "Lista", icon: Inbox },
  { id: "kanban", label: "Kanban", icon: Workflow },
];

interface CaseToolbarProps {
  filter: CaseListFilter;
  counts: CaseCounts | undefined;
  q: string;
  view: CaseView;
  onFilter: (filter: CaseListFilter) => void;
  onQuery: (q: string) => void;
  onView: (view: CaseView) => void;
}

export function CaseToolbar({ filter, counts, q, view, onFilter, onQuery, onView }: CaseToolbarProps) {
  const [draft, setDraft] = useSearchDraft(q, onQuery);
  const searchId = useId();

  return (
    <div className="mb-4 flex flex-wrap items-center gap-2 max-[600px]:gap-3">
      <div role="group" aria-label="Filtr spraw" className="flex flex-wrap gap-1 max-[600px]:gap-px">
        {FILTERS.map((item) => {
          const active = item.id === filter;
          return (
            <button
              key={item.id}
              type="button"
              aria-pressed={active}
              onClick={() => onFilter(item.id)}
              className={cn(
                "rounded-[6px] border px-2.5 py-2 text-[11px] text-muted-foreground outline-none focus-visible:ring-2 focus-visible:ring-ring/50 max-[600px]:p-[7px] max-[600px]:text-[10px]",
                active
                  ? "border-border bg-card text-foreground shadow-[0_1px_3px_#0000000a]"
                  : "border-transparent hover:text-foreground",
              )}
            >
              {item.label}
              {counts ? (
                <>
                  {" "}
                  <span className="ml-[5px] text-[10px] tabular-nums opacity-65">{counts[item.count]}</span>
                </>
              ) : null}
            </button>
          );
        })}
      </div>

      <div className="ml-auto flex w-[190px] items-center gap-2 rounded-[7px] border bg-card px-2.5 py-2 text-muted-foreground focus-within:ring-2 focus-within:ring-ring/50 max-[600px]:ml-0 max-[600px]:w-full">
        <Search aria-hidden className="size-3.5 shrink-0" strokeWidth={1.6} />
        <label htmlFor={searchId} className="sr-only">
          Szukaj spraw
        </label>
        <input
          id={searchId}
          type="search"
          value={draft}
          maxLength={MAX_SEARCH_LENGTH}
          onChange={(event) => setDraft(event.target.value)}
          placeholder="Szukaj sprawy…"
          className="w-full min-w-0 border-0 bg-transparent text-[11px] text-foreground outline-none placeholder:text-muted-foreground"
        />
      </div>

      <div
        role="group"
        aria-label="Widok spraw"
        className="inline-flex shrink-0 gap-[3px] rounded-[8px] border bg-muted p-[3px]"
      >
        {VIEWS.map(({ id, label, icon: Icon }) => (
          <button
            key={id}
            type="button"
            aria-pressed={view === id}
            onClick={() => onView(id)}
            className="flex items-center gap-1.5 rounded-[5px] px-[9px] py-1.5 text-[11px] text-muted-foreground outline-none focus-visible:ring-2 focus-visible:ring-ring/50 aria-pressed:bg-card aria-pressed:font-semibold aria-pressed:text-primary aria-pressed:shadow-[0_1px_4px_#20242f12]"
          >
            <Icon aria-hidden className="size-3.5" strokeWidth={1.6} />
            {label}
          </button>
        ))}
      </div>
    </div>
  );
}
