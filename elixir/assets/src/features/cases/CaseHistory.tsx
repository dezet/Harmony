import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { OPERATION_LABEL, providerErrorMessage } from "@/features/cases/useCaseActions";
import { useCaseEvents } from "@/features/cases/useCaseEvents";
import type { CaseEvent } from "@/types/contract";

// „Historia” tab (spec §4.4): detection, import, analysis, comment,
// notifications, retries and decisions, oldest first as the API returns them.
// Its data is the `[case-events, ref]` query of this case only, with its own
// loading, error and empty states. UTC timestamps are shown in the browser's
// time zone with the full date in the tooltip. Recipients arrive masked from
// the API; payloads are never rendered wholesale.

const EVENT_LABEL: Record<string, string> = {
  case_detected: "Wykryto zgłoszenie spełniające regułę",
  already_linked: "Zgłoszenie jest już powiązane z inną sprawą",
  linear_issue_confirmed: "Potwierdzono zadanie w Linear",
  analysis_queued: "Analiza w kolejce",
  analysis_work_run_started: "Uruchomiono sesję analizy",
  analysis_started: "Rozpoczęto analizę",
  analysis_completed: "Zapisano wynik analizy",
  analysis_failed: "Analiza zakończyła się błędem",
  analysis_recovered: "Wznowiono przerwaną analizę",
  analysis_reanalyze_requested: "Zlecono ponowną analizę",
  jira_comment_post_started: "Rozpoczęto publikację komentarza w Jira",
  jira_comment_post_rejected: "Jira odrzuciła komentarz",
  delivery_queued: "Zaplanowano wysyłkę",
  delivery_claimed: "Rozpoczęto próbę wysyłki",
  delivery_attempt: "Próba wysyłki",
  delivery_succeeded: "Wysyłka zakończona powodzeniem",
  delivery_failed: "Wysyłka nie powiodła się",
  delivery_unknown: "Wynik wysyłki nieznany",
  delivery_retry_scheduled: "Zaplanowano ponowienie wysyłki",
  delivery_rate_limited: "Dostawca ograniczył wysyłkę; ponowienie później",
  delivery_paused: "Wstrzymano wysyłkę",
  delivery_resumed: "Wznowiono wysyłkę",
  delivery_manual_retry: "Operator ponowił wysyłkę",
  case_acknowledged: "Sprawa przyjęta przez operatora",
  repair_approved: "Zatwierdzono naprawę",
  rule_disabled: "Reguła została wyłączona",
};

const OPERATIONS = new Set(Object.keys(OPERATION_LABEL));

const shortDate = new Intl.DateTimeFormat("pl-PL", { dateStyle: "short", timeStyle: "short" });
const fullDate = new Intl.DateTimeFormat("pl-PL", { dateStyle: "full", timeStyle: "long" });

function payloadText(payload: Record<string, unknown>, key: string): string | null {
  const value = payload[key];
  return typeof value === "string" || typeof value === "number" ? String(value) : null;
}

function eventDetails(event: CaseEvent): string[] {
  const details: string[] = [];
  const payloadOperation = payloadText(event.payload, "operation");
  const operation = event.operation ?? (payloadOperation && OPERATIONS.has(payloadOperation) ? payloadOperation : null);
  if (operation) {
    const label = OPERATION_LABEL[operation as keyof typeof OPERATION_LABEL];
    details.push(event.recipient ? `${label} · ${event.recipient}` : label);
  }
  const version = payloadText(event.payload, "analysis_version") ?? payloadText(event.payload, "version");
  if (version) details.push(`Wersja analizy ${version}`);
  const error = providerErrorMessage(payloadText(event.payload, "error_code"));
  if (error) details.push(error);
  if (event.actor === "operator") details.push("Operator");
  return details;
}

function HistoryLoading() {
  return (
    <div className="grid gap-3">
      <p role="status" className="sr-only">
        Wczytywanie historii…
      </p>
      {[0, 1, 2].map((row) => (
        <Skeleton key={row} aria-hidden className="h-10 w-full" />
      ))}
    </div>
  );
}

export function CaseHistory({ caseRef }: { caseRef: string }) {
  const events = useCaseEvents(caseRef);

  if (events.isPending) return <HistoryLoading />;

  if (events.isError && !events.data) {
    return (
      <div role="alert" className="grid justify-items-center gap-3 py-8 text-center text-xs text-muted-foreground">
        <p className="font-semibold text-destructive">Nie udało się wczytać historii.</p>
        <p>Pozostałe sekcje sprawy działają dalej.</p>
        <Button variant="outline" size="sm" onClick={() => void events.refetch()}>
          Spróbuj ponownie
        </Button>
      </div>
    );
  }

  const items = events.data?.pages.flatMap((page) => page.items) ?? [];
  if (items.length === 0) {
    return <p className="py-8 text-center text-xs text-muted-foreground">Brak zdarzeń w historii tej sprawy.</p>;
  }

  return (
    <div>
      <ol aria-label="Zdarzenia sprawy">
        {items.map((event) => {
          const date = new Date(event.occurred_at);
          const details = eventDetails(event);
          const label = EVENT_LABEL[event.type];
          return (
            <li key={event.id} className="flex gap-3.5 border-b py-[13px] text-xs leading-[1.65] last:border-b-0">
              <time
                dateTime={event.occurred_at}
                title={fullDate.format(date)}
                className="font-mono text-[11px] whitespace-nowrap text-muted-foreground"
              >
                {shortDate.format(date)}
              </time>
              <div className="min-w-0">
                {label ? <p className="text-foreground">{label}</p> : <p className="font-mono text-[11px] text-foreground">{event.type}</p>}
                {details.length > 0 ? <p className="text-[11px] text-muted-foreground">{details.join(" · ")}</p> : null}
              </div>
            </li>
          );
        })}
      </ol>
      {events.hasNextPage || events.isFetchNextPageError ? (
        <div className="grid justify-items-center gap-2 pt-3">
          {events.isFetchNextPageError ? (
            <p role="alert" className="text-[11px] text-destructive">
              Nie udało się wczytać kolejnych zdarzeń.
            </p>
          ) : null}
          <Button
            variant="outline"
            size="sm"
            disabled={events.isFetchingNextPage}
            onClick={() => void events.fetchNextPage()}
          >
            {events.isFetchingNextPage ? "Wczytywanie…" : "Pokaż więcej"}
          </Button>
        </div>
      ) : null}
      {events.isRefetchError ? (
        <p role="alert" className="pt-2 text-[11px] text-warning">
          Nie udało się odświeżyć historii. Pokazujemy ostatnio pobrane zdarzenia.
        </p>
      ) : null}
    </div>
  );
}
