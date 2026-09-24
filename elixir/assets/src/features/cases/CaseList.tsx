import type { ReactNode } from "react";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { useNow } from "@/lib/useNow";
import { CaseListItem } from "@/features/cases/CaseListItem";
import type { CaseSummary } from "@/types/contract";

// Case list of layout A: 25 cases per page from the backend order
// (detected_at desc, ref), "Pokaż więcej" for the next cursor, and designed
// loading, error and empty states instead of an endless spinner.

const plural = new Intl.PluralRules("pl-PL");

function casesLabel(total: number): string {
  const form = plural.select(total);
  if (form === "one") return `${total} sprawa`;
  if (form === "few") return `${total} sprawy`;
  return `${total} spraw`;
}

/** Polish count of cases: "1 sprawa", "3 sprawy", "25 spraw". */
export function CasesCount({ total }: { total: number }) {
  return casesLabel(total);
}

interface CaseListProps {
  status: "pending" | "error" | "success";
  items: CaseSummary[];
  total: number | undefined;
  selectedRef: string | null;
  /** The list has data but its latest refresh failed. */
  refreshFailed: boolean;
  hasNextPage: boolean;
  isFetchingNextPage: boolean;
  nextPageFailed: boolean;
  empty: ReactNode;
  onSelect: (ref: string) => void;
  onLoadMore: () => void;
  onRetry: () => void;
  className?: string;
}

function LoadingRows() {
  return (
    <div className="grid">
      <p role="status" className="sr-only">
        Wczytywanie spraw…
      </p>
      {[0, 1, 2].map((row) => (
        <div key={row} aria-hidden className="grid min-h-[119px] gap-2.5 border-b px-[19px] py-[18px] last:border-b-0">
          <Skeleton className="h-4 w-40" />
          <Skeleton className="h-4 w-3/4" />
          <Skeleton className="h-4 w-28" />
        </div>
      ))}
    </div>
  );
}

function LoadError({ onRetry }: { onRetry: () => void }) {
  return (
    <div role="alert" className="grid justify-items-center gap-3 px-6 py-10 text-center text-xs leading-[1.8] text-muted-foreground">
      <p className="font-semibold text-destructive">Nie udało się wczytać spraw.</p>
      <p>Serwer nie odpowiedział poprawnie. Dane nie zostały zmienione.</p>
      <Button variant="outline" size="sm" onClick={onRetry}>
        Spróbuj ponownie
      </Button>
    </div>
  );
}

export function CaseList(props: CaseListProps) {
  const { status, items, total, selectedRef, empty, onSelect } = props;
  const now = useNow(60_000);

  return (
    <section
      aria-label="Lista spraw"
      aria-busy={status === "pending"}
      className={cn("overflow-hidden rounded-[11px] border bg-card shadow-[0_1px_2px_#20242f0a]", props.className)}
    >
      <div className="flex items-center justify-between border-b px-[18px] py-[15px] text-[10px] text-muted-foreground">
        <h2 className="text-[10px] font-normal uppercase">Ostatnie zgłoszenia</h2>
        {status === "success" && total !== undefined ? <span>{casesLabel(total)}</span> : null}
      </div>

      {status === "pending" ? <LoadingRows /> : null}
      {status === "error" ? <LoadError onRetry={props.onRetry} /> : null}
      {status === "success" && items.length === 0 ? empty : null}

      {status === "success" && props.refreshFailed ? (
        <p role="alert" className="border-b bg-warning-surface px-[18px] py-2.5 text-[11px] text-warning">
          Nie udało się odświeżyć listy. Pokazujemy ostatnio pobrane dane.
        </p>
      ) : null}

      {status === "success" && items.length > 0 ? (
        <>
          <ul>
            {items.map((item) => (
              <CaseListItem
                key={item.ref}
                item={item}
                now={now}
                selected={item.ref === selectedRef}
                onSelect={onSelect}
              />
            ))}
          </ul>
          {props.hasNextPage || props.nextPageFailed ? (
            <div className="grid justify-items-center gap-2 border-t px-[18px] py-4">
              {props.nextPageFailed ? (
                <p role="alert" className="text-[11px] text-destructive">
                  Nie udało się wczytać kolejnych spraw.
                </p>
              ) : null}
              <Button
                variant="outline"
                size="sm"
                disabled={props.isFetchingNextPage}
                onClick={props.onLoadMore}
              >
                {props.isFetchingNextPage ? "Wczytywanie…" : "Pokaż więcej"}
              </Button>
            </div>
          ) : null}
        </>
      ) : null}
    </section>
  );
}
