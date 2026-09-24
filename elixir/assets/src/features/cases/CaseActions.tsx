import { useId, useState, type ReactNode } from "react";
import { Check, Loader2, RotateCcw, TriangleAlert } from "lucide-react";
import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { useProjects } from "@/features/projects/useProjects";
import {
  actionErrorMessage,
  OPERATION_RETRY_LABEL,
  providerErrorMessage,
  reasonMessage,
  useAcknowledgeCase,
  useApproveRepair,
  useReanalyzeCase,
  useRetryDelivery,
} from "@/features/cases/useCaseActions";
import type { CaseAction, CaseDelivery, CaseDetail, CaseDetailResponse, DeliveryOperation } from "@/types/contract";

// Case decisions (spec §4.4, §8.2, §9): „Przyjmij sprawę” and „Zatwierdź
// naprawę” are two separate mutations; approval and reanalysis need an
// explicit, described confirmation. Availability is exactly the backend
// `actions`; the reason code is shown in Polish. Results are announced in a
// polite live region, failures are shown at the action that failed.

const actionButton = "h-auto min-h-[30px] gap-[7px] rounded-[7px] px-[9px] py-1.5 text-[11px] font-[550] max-[600px]:flex-1";

const plural = new Intl.PluralRules("pl-PL");

function tokens(count: number): string {
  const form = plural.select(count);
  const word = form === "one" ? "token" : form === "few" ? "tokeny" : "tokenów";
  return `${count.toLocaleString("pl-PL")} ${word}`;
}

function ErrorText({ children }: { children: ReactNode }) {
  return (
    <p role="alert" className="flex items-start gap-1.5 text-[11px] leading-[1.5] text-destructive">
      <TriangleAlert aria-hidden className="mt-px size-3 shrink-0" strokeWidth={1.8} />
      {children}
    </p>
  );
}

interface ConfirmProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  confirmLabel: string;
  pending: boolean;
  onConfirm: () => void;
  children: ReactNode;
}

function Confirm({ open, onOpenChange, title, confirmLabel, pending, onConfirm, children }: ConfirmProps) {
  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent className="data-[size=default]:max-w-[calc(100%-2rem)] data-[size=default]:sm:max-w-md">
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          <AlertDialogDescription render={<div />} className="grid gap-2 text-left text-xs leading-[1.6]">
            {children}
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Anuluj</AlertDialogCancel>
          <Button disabled={pending} onClick={onConfirm}>
            {pending ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : null}
            {confirmLabel}
          </Button>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

interface ActionButtonProps {
  label: string;
  pendingLabel: string;
  action: CaseAction;
  reasonId: string;
  offline: boolean;
  busy: boolean;
  pending: boolean;
  primary?: boolean;
  onClick: () => void;
}

function ActionButton(props: ActionButtonProps) {
  const { label, pendingLabel, action, reasonId, offline, busy, pending, primary = false, onClick } = props;
  return (
    <Button
      variant={primary ? "default" : "outline"}
      size="sm"
      className={cn(actionButton, primary ? null : "bg-card")}
      disabled={!action.allowed || offline || busy}
      aria-describedby={action.allowed ? undefined : reasonId}
      onClick={onClick}
    >
      {pending ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : primary ? <Check aria-hidden /> : null}
      {label}
      {pending ? <span className="sr-only"> — {pendingLabel}</span> : null}
    </Button>
  );
}

function RepairSummary({ detail }: { detail: CaseDetail }) {
  const projects = useProjects();
  const project = projects.data?.find((entry) => entry.id === detail.case.project_id);
  const repository = project
    ? `${project.github_owner}/${project.github_repo}`
    : projects.isPending
      ? "Wczytywanie…"
      : "Nie udało się ustalić — sprawdź konfigurację projektu";

  return (
    <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 rounded-[7px] border bg-background px-3 py-2 text-foreground">
      <dt className="text-muted-foreground">Projekt</dt>
      <dd>{detail.case.project.name}</dd>
      <dt className="text-muted-foreground">Repozytorium</dt>
      <dd className="font-mono">{repository}</dd>
      <dt className="text-muted-foreground">Linear</dt>
      <dd className="font-mono">{detail.links.linear?.identifier ?? "brak potwierdzonego zadania"}</dd>
    </dl>
  );
}

interface CaseActionsProps {
  detail: CaseDetailResponse;
  offline: boolean;
}

export function CaseActions({ detail, offline }: CaseActionsProps) {
  const ref = detail.case.ref;
  const acknowledge = useAcknowledgeCase(ref);
  const approve = useApproveRepair(ref);
  const reanalyze = useReanalyzeCase(ref);
  const [confirm, setConfirm] = useState<"approve" | "reanalyze" | null>(null);
  const [announcement, setAnnouncement] = useState("");
  const idPrefix = useId();

  const { actions } = detail;
  const jiraOnly = [actions.acknowledge, actions.reanalyze, actions.approve_repair].every(
    (action) => !action.allowed && action.reason === "unsupported_case_kind",
  );
  if (jiraOnly || detail.version === null) {
    return (
      <p className="text-[11px] leading-[1.6] text-muted-foreground">
        Decyzje dotyczą tylko spraw z Jira. Tę pracę prowadzisz w szczególe przebiegu agenta.
      </p>
    );
  }

  const jira = detail as CaseDetail;
  const busy = acknowledge.isPending || approve.isPending || reanalyze.isPending;
  const failure = [acknowledge, approve, reanalyze].find((mutation) => mutation.isError)?.error;
  const lastTokens = jira.analysis?.token_usage?.total_tokens;
  const denied = (
    [
      ["acknowledge", "Przyjęcie", actions.acknowledge],
      ["approve", "Naprawa", actions.approve_repair],
      ["reanalyze", "Ponowna analiza", actions.reanalyze],
    ] as const
  ).filter(([, , action]) => !action.allowed);

  const onAcknowledge = () => {
    setAnnouncement("");
    acknowledge.mutate(jira.version, {
      onSuccess: () => setAnnouncement("Sprawa przyjęta. Nie uruchamia to naprawy ani nie zmienia Jira i Linear."),
    });
  };

  const onApprove = () => {
    setAnnouncement("");
    approve.mutate(
      { expectedVersion: jira.version, analysisVersion: jira.case.analysis_version },
      {
        onSuccess: () => setAnnouncement("Naprawa zatwierdzona — oczekuje na uruchomienie."),
        onSettled: () => setConfirm(null),
      },
    );
  };

  const onReanalyze = () => {
    setAnnouncement("");
    reanalyze.mutate(jira.version, {
      onSuccess: (result) => setAnnouncement(`Zlecono analizę w wersji ${result.analysis_version}.`),
      onSettled: () => setConfirm(null),
    });
  };

  const reset = () => {
    acknowledge.reset();
    approve.reset();
    reanalyze.reset();
  };

  return (
    <div role="group" aria-label="Akcje sprawy" className="grid gap-2">
      <div className="flex flex-wrap justify-end gap-2">
        <ActionButton
          label="Przeanalizuj ponownie"
          pendingLabel="zlecanie…"
          action={actions.reanalyze}
          reasonId={`${idPrefix}-reanalyze`}
          offline={offline}
          busy={busy}
          pending={reanalyze.isPending}
          onClick={() => {
            reset();
            setConfirm("reanalyze");
          }}
        />
        <ActionButton
          label="Zatwierdź naprawę"
          pendingLabel="zatwierdzanie…"
          action={actions.approve_repair}
          reasonId={`${idPrefix}-approve`}
          offline={offline}
          busy={busy}
          pending={approve.isPending}
          onClick={() => {
            reset();
            setConfirm("approve");
          }}
        />
        <ActionButton
          label="Przyjmij sprawę"
          pendingLabel="przyjmowanie…"
          action={actions.acknowledge}
          reasonId={`${idPrefix}-acknowledge`}
          offline={offline}
          busy={busy}
          pending={acknowledge.isPending}
          primary
          onClick={() => {
            reset();
            onAcknowledge();
          }}
        />
      </div>

      {denied.length > 0 ? (
        <ul className="grid gap-0.5 text-right text-[10px] leading-[1.5] text-muted-foreground max-[600px]:text-left">
          {denied.map(([key, label, action]) => (
            <li key={key}>
              {label}: <span id={`${idPrefix}-${key}`}>{reasonMessage(action.reason)}</span>
            </li>
          ))}
        </ul>
      ) : null}

      {failure ? <ErrorText>{actionErrorMessage(failure)}</ErrorText> : null}

      <p role="status" aria-live="polite" aria-label="Wynik akcji" className="text-right text-[11px] text-success max-[600px]:text-left">
        {announcement}
      </p>

      <Confirm
        open={confirm === "approve"}
        onOpenChange={(open) => setConfirm(open ? "approve" : null)}
        title="Zatwierdzić naprawę?"
        confirmLabel="Zatwierdź naprawę"
        pending={approve.isPending}
        onConfirm={onApprove}
      >
        <p>
          Harmony przekaże sprawę do istniejącego przepływu pracy agenta. Agent może zmienić kod w repozytorium i
          przygotować pull request.
        </p>
        <RepairSummary detail={jira} />
        <p>
          Zgoda dotyczy analizy w wersji {jira.case.analysis_version}. Status w Jira się nie zmieni i nie powstanie drugie
          zadanie w Linear. Uruchomienie nastąpi, gdy pozwolą na to dostępność agentów i zasady projektu.
        </p>
      </Confirm>

      <Confirm
        open={confirm === "reanalyze"}
        onOpenChange={(open) => setConfirm(open ? "reanalyze" : null)}
        title="Przeanalizować ponownie?"
        confirmLabel="Przeanalizuj ponownie"
        pending={reanalyze.isPending}
        onConfirm={onReanalyze}
      >
        <p>
          Ponowna analiza uruchamia model językowy, a jego użycie jest płatne. Powstanie wersja{" "}
          {jira.case.analysis_version + 1} z nowym kontekstem; poprzednie wyniki zostaną w historii.
        </p>
        {lastTokens ? <p>Poprzednia analiza zużyła {tokens(lastTokens)}.</p> : null}
        <p>Nowy wynik trafi do Jira jako nowy komentarz i będzie wymagał ponownego przyjęcia sprawy.</p>
      </Confirm>
    </div>
  );
}

const RETRY_TITLE: Record<DeliveryOperation, string> = {
  linear_create: "Ponowić utworzenie zadania w Linear?",
  email: "Ponowić e-mail?",
  sms: "Ponowić SMS?",
  analysis: "Ponowić analizę?",
  jira_comment: "Ponowić publikację komentarza?",
};

interface DeliveryRetryProps {
  caseRef: string;
  delivery: CaseDelivery;
  offline: boolean;
}

/** Retry of a single delivery; shown only when the backend allows it. */
export function DeliveryRetry({ caseRef, delivery, offline }: DeliveryRetryProps) {
  const retry = useRetryDelivery(caseRef);
  const [confirming, setConfirming] = useState(false);
  const [announcement, setAnnouncement] = useState("");

  if (!delivery.retry_allowed) return null;

  const send = (confirmDuplicateRisk: boolean) => {
    setAnnouncement("");
    retry.mutate(
      { id: delivery.id, expectedStatus: delivery.status, confirmDuplicateRisk },
      {
        onSuccess: () => setAnnouncement("Ponowienie zakolejkowane."),
        onSettled: () => setConfirming(false),
      },
    );
  };

  return (
    <div className="grid justify-items-start gap-1">
      <Button
        variant="outline"
        size="sm"
        className={cn(actionButton, "bg-card")}
        disabled={offline || retry.isPending}
        onClick={() => (delivery.duplicate_risk ? setConfirming(true) : send(false))}
      >
        {retry.isPending ? (
          <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" />
        ) : (
          <RotateCcw aria-hidden />
        )}
        {OPERATION_RETRY_LABEL[delivery.operation]}
      </Button>
      {retry.isError ? <ErrorText>{actionErrorMessage(retry.error)}</ErrorText> : null}
      <p role="status" aria-live="polite" className="text-[10px] text-success">
        {announcement}
      </p>
      {delivery.duplicate_risk ? (
        <Confirm
          open={confirming}
          onOpenChange={setConfirming}
          title={RETRY_TITLE[delivery.operation]}
          confirmLabel="Ponów mimo ryzyka"
          pending={retry.isPending}
          onConfirm={() => send(true)}
        >
          <p>
            Poprzednia próba mogła już dotrzeć do dostawcy, ale Harmony nie zna jej wyniku. Ponowienie może wysłać
            duplikat wiadomości.
          </p>
          <p>Ponawiamy tylko tę jedną wysyłkę, nie cały przebieg sprawy.</p>
        </Confirm>
      ) : null}
    </div>
  );
}

/** Footer state of the Jira comment (spec §9.3): published, failed or unknown, with its retry. */
export function PublicationStatus({ detail, offline }: { detail: CaseDetailResponse; offline: boolean }) {
  if (detail.version === null || !detail.publication) return <span className="mr-auto" />;

  const jira = detail as CaseDetail;
  const { publication } = jira;
  const comment = jira.deliveries.filter((delivery) => delivery.operation === "jira_comment").at(-1);

  if (!jira.analysis?.result) {
    return (
      <span className="mr-auto flex items-center gap-[5px] text-[10px] text-muted-foreground">
        {jira.links.linear ? "Zadanie utworzone w Linear" : null}
      </span>
    );
  }

  if (publication.status === "published") {
    return (
      <span className="mr-auto flex items-center gap-[5px] text-[10px] text-success max-[600px]:mb-1 max-[600px]:w-full">
        <Check aria-hidden className="size-[13px]" strokeWidth={1.8} />
        Analiza opublikowana w Jira
      </span>
    );
  }

  if (publication.status === "pending") {
    return (
      <span className="mr-auto text-[10px] text-muted-foreground max-[600px]:mb-1 max-[600px]:w-full">
        Komentarz z analizą czeka na publikację w Jira
      </span>
    );
  }

  const failed = publication.status === "failed";
  return (
    <div
      role="group"
      aria-label="Publikacja w Jira"
      className="mr-auto grid gap-1 text-[10px] leading-[1.5] max-[600px]:mb-1 max-[600px]:w-full"
    >
      <p className={cn("flex items-center gap-[5px] font-[550]", failed ? "text-destructive" : "text-warning")}>
        <TriangleAlert aria-hidden className="size-[13px]" strokeWidth={1.8} />
        {failed ? "Analiza gotowa; błąd publikacji" : "Nie wiadomo, czy komentarz trafił do Jira"}
      </p>
      <p className="text-muted-foreground">
        {providerErrorMessage(publication.error_code) ?? null}
        {failed ? null : " Sprawdź komentarze w Jira przed ponowieniem."}
      </p>
      {comment ? <DeliveryRetry caseRef={jira.case.ref} delivery={comment} offline={offline} /> : null}
    </div>
  );
}
