import { useId, useMemo } from "react";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { CaseBoardCard } from "@/features/cases/CaseBoardCard";
import { CasesCount } from "@/features/cases/CaseList";
import { useCaseColumn } from "@/features/cases/useCases";
import type { CaseColumn as CaseColumnId, CaseFilters } from "@/types/contract";

// One Kanban column: its own `GET /cases?column=` pages of 25, its own
// cursor and "Pokaż więcej", and its own loading, error and empty states, so a
// failing column never blocks the others. The header count is the backend
// total of the column, not the number of loaded cards.

const COLUMN_META: Record<CaseColumnId, { label: string; dot: string }> = {
  detected: { label: "Wykryte", dot: "bg-muted-foreground" },
  analyzing: { label: "W analizie", dot: "bg-[#a5a0e1]" },
  decision: { label: "Do decyzji", dot: "bg-[#d1ae79]" },
  handed_off: { label: "Przekazane", dot: "bg-[#9bc5a4]" },
};

interface CaseColumnProps {
  column: CaseColumnId;
  filters: CaseFilters;
  selectedRef: string | null;
  now: number;
  onOpen: (ref: string) => void;
}

function LoadingCards() {
  return (
    <div className="grid gap-2.5">
      <p role="status" className="sr-only">
        Wczytywanie spraw…
      </p>
      {[0, 1].map((card) => (
        <div key={card} aria-hidden className="grid gap-2.5 rounded-[7px] border bg-card px-[13px] py-4">
          <Skeleton className="h-4 w-24" />
          <Skeleton className="h-4 w-3/4" />
          <Skeleton className="h-4 w-20" />
        </div>
      ))}
    </div>
  );
}

export function CaseColumn({ column, filters, selectedRef, now, onOpen }: CaseColumnProps) {
  const query = useCaseColumn(filters, column);
  const headingId = useId();
  const { label, dot } = COLUMN_META[column];

  const items = useMemo(() => query.data?.pages.flatMap((page) => page.items) ?? [], [query.data]);
  const total = query.data?.pages[0]?.meta.total;
  const status = query.data ? "success" : query.isError ? "error" : "pending";

  return (
    <section
      aria-labelledby={headingId}
      aria-busy={status === "pending"}
      className="min-h-[462px] min-w-0 rounded-[9px] border bg-sidebar p-2.5 max-[1150px]:min-h-[260px] max-[600px]:min-h-0 max-[600px]:p-3"
    >
      <div className="flex items-center gap-[7px] px-0.5 pt-[7px] pb-4">
        <span aria-hidden className={cn("size-[7px] shrink-0 rounded-full", dot)} />
        <h2 id={headingId} className="text-[11px] font-[550] text-foreground">
          {label}
        </h2>
        {total !== undefined ? (
          <span className="ml-auto text-[10px] text-muted-foreground">
            <span aria-hidden>{total}</span>
            <span className="sr-only">
              <CasesCount total={total} />
            </span>
          </span>
        ) : null}
      </div>

      {status === "pending" ? <LoadingCards /> : null}

      {status === "error" ? (
        <div role="alert" className="grid justify-items-center gap-2 px-2 py-6 text-center text-[11px] leading-[1.7] text-muted-foreground">
          <p className="font-semibold text-destructive">Nie udało się wczytać kolumny.</p>
          <p>Serwer nie odpowiedział poprawnie. Pozostałe kolumny działają dalej.</p>
          <Button variant="outline" size="sm" disabled={query.isFetching} onClick={() => void query.refetch()}>
            Spróbuj ponownie
          </Button>
        </div>
      ) : null}

      {status === "success" && query.isRefetchError ? (
        <p role="alert" className="mb-2.5 rounded-[7px] bg-warning-surface px-2.5 py-2 text-[10px] leading-[1.6] text-warning">
          Nie udało się odświeżyć kolumny. Pokazujemy ostatnio pobrane dane.
        </p>
      ) : null}

      {status === "success" && items.length === 0 ? (
        <p className="p-2 text-[10px] leading-[1.7] text-muted-foreground">Brak spraw na tym etapie.</p>
      ) : null}

      {items.length > 0 ? (
        <ul className="grid gap-2.5">
          {items.map((item) => (
            <CaseBoardCard key={item.ref} item={item} now={now} selected={item.ref === selectedRef} onOpen={onOpen} />
          ))}
        </ul>
      ) : null}

      {status === "success" && (query.hasNextPage || query.isFetchNextPageError) ? (
        <div className="mt-2.5 grid justify-items-center gap-2">
          {query.isFetchNextPageError ? (
            <p role="alert" className="text-[11px] text-destructive">
              Nie udało się wczytać kolejnych spraw.
            </p>
          ) : null}
          <Button
            variant="outline"
            size="sm"
            className="bg-card"
            disabled={query.isFetchingNextPage}
            onClick={() => void query.fetchNextPage()}
          >
            {query.isFetchingNextPage ? "Wczytywanie…" : "Pokaż więcej"}
          </Button>
        </div>
      ) : null}
    </section>
  );
}
