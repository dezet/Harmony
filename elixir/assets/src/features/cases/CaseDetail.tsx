import { useId, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { ShieldCheck, TriangleAlert, WifiOff } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { ApiError } from "@/lib/api";
import { cn } from "@/lib/utils";
import { CaseActions, DeliveryRetry, PublicationStatus } from "@/features/cases/CaseActions";
import { CaseAnalysis } from "@/features/cases/CaseAnalysis";
import { CaseHistory } from "@/features/cases/CaseHistory";
import { CaseStatusBadge, PriorityBadge } from "@/features/cases/CaseListItem";
import { ExternalIssueLink } from "@/features/cases/ExternalIssueLink";
import { useCase } from "@/features/cases/useCase";
import {
  DELIVERY_STATUS_LABEL,
  OPERATION_LABEL,
  providerErrorMessage,
  useActionsOffline,
} from "@/features/cases/useCaseActions";
import type { CaseTab } from "@/features/cases/useCaseFilters";
import type {
  AgentWorkDetail,
  CaseDelivery,
  CaseDetail as CaseDetailData,
  CaseDetailResponse,
  CaseExecutionMode,
  DeliveryStatus,
} from "@/types/contract";

// Case detail of layout A (spec §4.4): identifiers, title, project, priority,
// status and execution mode, three tabs (Analiza / Zgłoszenie / Historia) and
// the footer with the Jira/Linear links and the case decisions. The same
// component is the desktop side panel, the phone dialog and the standalone
// `/cases/:ref` page; its data is only the `[case, ref]` query of this ref.

const MODE_LABEL: Record<CaseExecutionMode, string> = {
  analysis_only: "Tylko analiza",
  repair_approved: "Naprawa zatwierdzona",
  existing_workflow: "Istniejąca praca agenta",
};

const STATUS_TONE: Record<DeliveryStatus, string> = {
  pending: "bg-muted text-muted-foreground",
  running: "bg-accent text-accent-foreground",
  retry_wait: "bg-warning-surface text-warning",
  succeeded: "bg-success-surface text-success",
  failed: "bg-destructive-surface text-destructive",
  unknown: "bg-warning-surface text-warning",
  paused: "bg-muted text-muted-foreground",
};

const tag = "inline-flex items-center gap-[5px] rounded-[5px] border px-1.5 py-1 text-[10px] text-muted-foreground";
const tabClass =
  "h-auto flex-none rounded-none border-0 px-0 pb-2.5 text-[11px] font-normal text-muted-foreground data-active:font-semibold data-active:text-primary after:bg-primary group-data-horizontal/tabs:after:bottom-[-1px] dark:data-active:bg-transparent dark:data-active:text-primary";

const dateTime = new Intl.DateTimeFormat("pl-PL", { dateStyle: "medium", timeStyle: "short" });
const fullDate = new Intl.DateTimeFormat("pl-PL", { dateStyle: "full", timeStyle: "long" });

function When({ iso }: { iso: string }) {
  const date = new Date(iso);
  return (
    <time dateTime={iso} title={fullDate.format(date)}>
      {dateTime.format(date)}
    </time>
  );
}

function isAgentWork(detail: CaseDetailResponse): detail is AgentWorkDetail {
  return detail.case.kind === "agent_work" || detail.version === null;
}

function Eyebrow({ children }: { children: ReactNode }) {
  return <h3 className="mb-1 text-[10px] font-semibold tracking-wide text-muted-foreground uppercase">{children}</h3>;
}

function Facts({ rows }: { rows: [string, ReactNode][] }) {
  return (
    <dl className="grid grid-cols-[minmax(0,auto)_1fr] gap-x-4 gap-y-1 text-xs leading-[1.7]">
      {rows.map(([label, value]) => (
        <div key={label} className="contents">
          <dt className="text-muted-foreground">{label}</dt>
          <dd className="min-w-0 break-words text-foreground">{value}</dd>
        </div>
      ))}
    </dl>
  );
}

function DeliveryRow({ caseRef, delivery, offline }: { caseRef: string; delivery: CaseDelivery; offline: boolean }) {
  const error = providerErrorMessage(delivery.last_error_code);
  return (
    <li className="grid gap-1.5 border-b py-3 text-xs last:border-b-0">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-semibold text-foreground">{OPERATION_LABEL[delivery.operation]}</span>
        <span className={cn("rounded-[5px] px-[7px] py-0.5 text-[10px] font-[550]", STATUS_TONE[delivery.status])}>
          {DELIVERY_STATUS_LABEL[delivery.status]}
        </span>
        <span className="ml-auto text-[10px] text-muted-foreground">Próby: {delivery.attempts}</span>
      </div>
      <p className="text-[11px] text-muted-foreground">
        {delivery.sent_at ? (
          <>
            Wysłano <When iso={delivery.sent_at} />
          </>
        ) : delivery.next_attempt_at ? (
          <>
            Następna próba <When iso={delivery.next_attempt_at} />
          </>
        ) : delivery.first_attempt_at ? (
          <>
            Pierwsza próba <When iso={delivery.first_attempt_at} />
          </>
        ) : (
          "Jeszcze bez próby"
        )}
        {error ? <span className="text-destructive"> · {error}</span> : null}
      </p>
      <DeliveryRetry caseRef={caseRef} delivery={delivery} offline={offline} />
    </li>
  );
}

function JiraIssue({ detail, offline }: { detail: CaseDetailData; offline: boolean }) {
  const { case: item } = detail;
  const rule = item.rule_snapshot;
  return (
    <div className="grid gap-5">
      <section>
        <Eyebrow>Opis zgłoszenia</Eyebrow>
        {item.description_text ? (
          <p className="text-[13px] leading-[1.85] break-words whitespace-pre-wrap text-foreground">{item.description_text}</p>
        ) : (
          <p className="text-xs text-muted-foreground">Zgłoszenie nie ma opisu.</p>
        )}
      </section>
      <section>
        <Eyebrow>Kontekst</Eyebrow>
        <Facts
          rows={[
            ["Projekt", item.project.name],
            ["Źródło", `Jira · ${item.jira?.key ?? "—"}`],
            ["Zmiana w Jira", <When key="jira" iso={item.jira_updated_at} />],
            ["Wykryto", <When key="detected" iso={item.detected_at} />],
            ["Priorytet", item.priority.label],
            [
              "Docelowy Linear",
              detail.links.linear
                ? `${detail.links.linear.identifier}${item.linear_state_name ? ` · ${item.linear_state_name}` : ""}`
                : "Zadanie nie zostało jeszcze potwierdzone",
            ],
            ["Reguła", `${rule.name} · ${rule.source_type === "board" ? "tablica" : "filtr"} ${rule.source_id}`],
          ]}
        />
      </section>
      <section>
        <Eyebrow>Efekty integracji</Eyebrow>
        {detail.deliveries.length > 0 ? (
          <ul aria-label="Efekty integracji">
            {detail.deliveries.map((delivery) => (
              <DeliveryRow key={delivery.id} caseRef={item.ref} delivery={delivery} offline={offline} />
            ))}
          </ul>
        ) : (
          <p className="text-xs text-muted-foreground">Brak efektów integracji dla tej sprawy.</p>
        )}
      </section>
      <p className="flex items-start gap-[9px] rounded-[7px] border bg-background p-3 text-[11px] leading-[1.7] text-muted-foreground">
        <ShieldCheck aria-hidden className="mt-0.5 size-[15px] shrink-0 text-primary" strokeWidth={1.6} />
        Ta automatyzacja tworzy analizę i komentarz. Przygotowanie zmiany w kodzie wymaga osobnej zgody.
      </p>
    </div>
  );
}

function LegacyIssue({ detail }: { detail: AgentWorkDetail }) {
  const { work_run: run, project, linear } = detail.case;
  const forge = run.forge;
  return (
    <div className="grid gap-5">
      <section>
        <Eyebrow>Praca agenta</Eyebrow>
        <Facts
          rows={[
            ["Projekt", project.name],
            ["Rodzaj", run.type],
            ["Stan przebiegu", run.status],
            ["Agent", run.agent_backend ?? "—"],
            ["Wykryto", <When key="detected" iso={detail.case.detected_at} />],
            ["Priorytet", detail.case.priority.label],
            [
              "Repozytorium",
              forge?.owner && forge.repo
                ? `${forge.owner}/${forge.repo}${forge.pr_number ? ` · PR #${forge.pr_number}` : ""}`
                : "—",
            ],
          ]}
        />
      </section>
      {linear ? (
        <Link
          className="text-xs text-primary underline underline-offset-4"
          to={`/projects/${encodeURIComponent(project.slug)}/runs/${encodeURIComponent(linear.identifier)}`}
        >
          Szczegół przebiegu
        </Link>
      ) : null}
    </div>
  );
}

function DetailLoading() {
  return (
    <div className="grid gap-3">
      <p role="status" className="sr-only">
        Wczytywanie sprawy…
      </p>
      <Skeleton aria-hidden className="h-4 w-40" />
      <Skeleton aria-hidden className="h-7 w-3/4" />
      <Skeleton aria-hidden className="h-4 w-56" />
      <Skeleton aria-hidden className="h-40 w-full" />
    </div>
  );
}

function DetailError({ notFound, onRetry }: { notFound: boolean; onRetry: () => void }) {
  if (notFound) {
    return (
      <div className="grid gap-2 text-xs leading-[1.6] text-muted-foreground">
        <h2 className="text-lg font-semibold text-foreground">Nie znaleziono sprawy</h2>
        <p>Ta sprawa nie istnieje albo została usunięta.</p>
        <Link className="text-primary underline underline-offset-4" to="/">
          Wróć do Centrum spraw
        </Link>
      </div>
    );
  }
  return (
    <div role="alert" className="grid justify-items-start gap-3 text-xs leading-[1.6] text-muted-foreground">
      <p className="font-semibold text-destructive">Nie udało się wczytać sprawy.</p>
      <p>Serwer nie odpowiedział poprawnie. Dane nie zostały zmienione.</p>
      <Button variant="outline" size="sm" onClick={onRetry}>
        Spróbuj ponownie
      </Button>
    </div>
  );
}

interface CaseDetailProps {
  caseRef: string;
  tab: CaseTab;
  onTabChange: (tab: CaseTab) => void;
  /** h1 on the standalone page, h2 inside the Case Center. */
  titleAs?: "h1" | "h2";
  /** The Case Center shows its own page-wide offline notice. */
  showOfflineNotice?: boolean;
}

export function CaseDetail({ caseRef, tab, onTabChange, titleAs = "h2", showOfflineNotice = true }: CaseDetailProps) {
  const titleId = useId();
  const query = useCase(caseRef);
  const offline = useActionsOffline();

  if (query.isPending) return <DetailLoading />;
  if (!query.data) {
    const notFound = query.error instanceof ApiError && query.error.status === 404;
    return <DetailError notFound={notFound} onRetry={() => void query.refetch()} />;
  }

  const detail = query.data;
  const item = detail.case;
  const legacy = isAgentWork(detail);
  const Title = titleAs;

  return (
    <article aria-labelledby={titleId} className="min-w-0">
      <div className="mb-3 flex items-center gap-2">
        <span className="font-mono text-[11px] text-muted-foreground">{item.jira?.key ?? item.linear?.identifier ?? ""}</span>
        <PriorityBadge priority={item.priority} />
        <span data-slot="case-project" className="ml-auto truncate text-[10px] text-muted-foreground">
          {item.project.name}
        </span>
      </div>
      <Title
        id={titleId}
        className="max-w-[560px] text-[23px] leading-[1.35] font-semibold tracking-[-0.6px] text-foreground max-[1150px]:text-xl max-[600px]:text-[22px]"
      >
        {item.title}
      </Title>
      <div className="mt-[13px] flex flex-wrap items-center gap-[9px]">
        <CaseStatusBadge column={item.column} label={item.status_label} />
        {item.jira ? (
          <span className={tag}>
            <span aria-hidden className="inline-block size-2.5 rotate-45 rounded-[1px] bg-[#3976d0]" />
            {item.jira.key}
          </span>
        ) : null}
        {item.linear ? (
          <span className={tag}>
            <span
              aria-hidden
              className="inline-block size-[11px] rounded-full bg-[repeating-linear-gradient(45deg,#8a82da_0px,#8a82da_2px,transparent_2px,transparent_3px)]"
            />
            {item.linear.identifier}
          </span>
        ) : null}
        <span className={tag}>{MODE_LABEL[item.execution_mode]}</span>
      </div>

      {item.attention ? (
        <p className="mt-3 flex items-start gap-1.5 rounded-[7px] bg-warning-surface px-3 py-2 text-[11px] leading-[1.5] text-warning">
          <TriangleAlert aria-hidden className="mt-px size-3 shrink-0" strokeWidth={1.8} />
          {item.attention.message}
        </p>
      ) : null}
      {query.isRefetchError ? (
        <p role="alert" className="mt-3 rounded-[7px] bg-warning-surface px-3 py-2 text-[11px] text-warning">
          Nie udało się odświeżyć sprawy. Pokazujemy ostatnio pobrane dane.
        </p>
      ) : null}
      {offline && showOfflineNotice ? (
        <p role="alert" className="mt-3 flex items-center gap-2 rounded-[7px] bg-warning-surface px-3 py-2 text-[11px] text-warning">
          <WifiOff aria-hidden className="size-3.5 shrink-0" strokeWidth={1.6} />
          Brak połączenia z serwerem. Pokazujemy ostatnio pobrane dane; akcje są wyłączone.
        </p>
      ) : null}

      <Tabs value={tab} onValueChange={(value) => onTabChange(value as CaseTab)} className="mt-[21px] gap-5">
        <TabsList
          variant="line"
          aria-label="Sekcje sprawy"
          className="w-full justify-start gap-[21px] rounded-none border-b p-0 group-data-horizontal/tabs:h-auto max-[600px]:gap-[17px]"
        >
          <TabsTrigger value="analysis" className={tabClass}>
            Analiza
          </TabsTrigger>
          <TabsTrigger value="issue" className={tabClass}>
            Zgłoszenie
          </TabsTrigger>
          <TabsTrigger value="history" className={tabClass}>
            Historia
          </TabsTrigger>
        </TabsList>
        <TabsContent value="analysis">
          <CaseAnalysis detail={detail} />
        </TabsContent>
        <TabsContent value="issue">
          {legacy ? <LegacyIssue detail={detail} /> : <JiraIssue detail={detail as CaseDetailData} offline={offline} />}
        </TabsContent>
        <TabsContent value="history">
          <CaseHistory caseRef={item.ref} />
        </TabsContent>
      </Tabs>

      <div className="mt-5 grid gap-3 border-t pt-4">
        <div className="flex flex-wrap items-center gap-2">
          <PublicationStatus detail={detail} offline={offline} />
          <ExternalIssueLink
            tracker="jira"
            url={detail.links.jira?.url}
            unavailableReason={legacy ? "Brak powiązania Jira." : "Brak linku do zgłoszenia Jira."}
          />
          <ExternalIssueLink
            tracker="linear"
            url={detail.links.linear?.url}
            unavailableReason={
              legacy ? "Brak powiązanego zadania Linear." : "Zadanie Linear nie zostało jeszcze potwierdzone."
            }
          />
        </div>
        <CaseActions detail={detail} offline={offline} />
      </div>
    </article>
  );
}
