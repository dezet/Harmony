import type { ReactNode } from "react";
import { Bell, Check, ExternalLink, Link2, Loader2, Sparkles, TriangleAlert } from "lucide-react";
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
import { importCount, issuesCount } from "@/features/automations/useAutomations";
import type {
  AutomationInitialPolicy,
  AutomationPreview,
  AutomationPreviewWarning,
  AutomationRule,
  AutomationSourceType,
  Project,
} from "@/types/contract";

// „Podgląd działania” of layout A: the rule in plain language, the dry-run
// result of the saved version and the activation confirmation. Nothing here
// sends anything; the texts only describe what the backend reported.

const plural = new Intl.PluralRules("pl-PL");

function few(count: number): boolean {
  return plural.select(count) === "few";
}

function Accent({ children }: { children: ReactNode }) {
  return <strong className="font-semibold text-primary">{children}</strong>;
}

export interface RuleSummaryProps {
  intervalText: string | null;
  sourceType: AutomationSourceType;
  sourceLabel: string | null;
  priorityNames: string[];
  email: boolean;
  sms: boolean;
  policy: AutomationInitialPolicy;
}

function notifyText(email: boolean, sms: boolean): string {
  if (email && sms) return "Wyślij e-mail i SMS.";
  if (email) return "Wyślij e-mail.";
  if (sms) return "Wyślij SMS.";
  return "Nie wysyłaj powiadomień.";
}

/** The rule in plain language, built from the current form values. */
export function RuleSummary({ intervalText, sourceType, sourceLabel, priorityNames, email, sms, policy }: RuleSummaryProps) {
  const sourceWord = sourceType === "board" ? "tablicę" : "zapisany filtr";
  return (
    <>
      <p data-testid="rule-summary" className="text-[13px] leading-[1.9]">
        Co <Accent>{intervalText ?? "— podaj częstotliwość"}</Accent> sprawdzaj {sourceWord}{" "}
        <Accent>{sourceLabel ?? "— wybierz źródło"}</Accent>. Gdy zgłoszenie pierwszy raz otrzyma priorytet{" "}
        <Accent>{priorityNames.length > 0 ? priorityNames.join(" lub ") : "— wybierz priorytet"}</Accent>, utwórz sprawę
        i rozpocznij analizę.
      </p>
      <ul className="mt-5 list-none p-0 text-[11px] leading-[1.6]">
        {[
          { icon: Bell, text: notifyText(email, sms) },
          { icon: Link2, text: "Utwórz jedno powiązane zadanie Todo w Linear." },
          { icon: Sparkles, text: "Przeanalizuj problem w kontekście projektu." },
          { icon: Check, text: "Opublikuj wynik jako komentarz w Jira." },
        ].map(({ icon: Icon, text }) => (
          <li key={text} className="flex gap-2.5 border-t py-[11px]">
            <Icon aria-hidden className="mt-px size-[15px] shrink-0 text-primary" strokeWidth={1.6} />
            <span>{text}</span>
          </li>
        ))}
        <li className="flex gap-2.5 border-t py-[11px] text-muted-foreground">
          <Check aria-hidden className="mt-px size-[15px] shrink-0 text-primary" strokeWidth={1.6} />
          <span>
            {policy === "new_matches_only"
              ? "Przy aktywacji zgłoszenia pasujące już teraz zostaną pominięte jako stan początkowy."
              : "Przy aktywacji zgłoszenia pasujące już teraz zostaną zaimportowane jako nowe sprawy."}
          </span>
        </li>
      </ul>
    </>
  );
}

function warning<T extends AutomationPreviewWarning["code"]>(preview: AutomationPreview, code: T) {
  return preview.warnings.find((entry) => entry.code === code);
}

function projectNames(rules: { project_id: string }[] | undefined, projects: Project[] | undefined): string {
  const names = [...new Set((rules ?? []).map((entry) => entry.project_id))].map((id) => {
    const project = projects?.find((candidate) => candidate.id === id);
    return project ? project.display_name || project.slug : "nieznany projekt";
  });
  return names.join(", ");
}

export function SourceConflict({ preview, projects }: { preview: AutomationPreview; projects: Project[] | undefined }) {
  const conflict = warning(preview, "source_conflict");
  if (!conflict) return null;
  return (
    <p
      role="alert"
      aria-label="Kolizja źródła"
      className="flex gap-2 rounded-[7px] border border-warning/30 bg-warning-surface p-3 text-[11px] leading-[1.7] text-warning"
    >
      <TriangleAlert aria-hidden className="mt-0.5 size-3.5 shrink-0" strokeWidth={1.8} />
      <span>
        Kolizja: to samo źródło obserwuje już aktywna reguła w projekcie {projectNames(conflict.rules, projects)}. Dopóki
        tamta reguła działa, aktywacja tej zostanie odrzucona.
      </span>
    </p>
  );
}

function safeUrl(url: string | null): string | null {
  if (!url) return null;
  try {
    return new URL(url).protocol === "https:" ? url : null;
  } catch {
    return null;
  }
}

interface PreviewResultProps {
  preview: AutomationPreview;
  policy: AutomationInitialPolicy;
  firstBaseline: boolean;
  projects: Project[] | undefined;
}

/** Dry-run result of the saved version (spec §7.1): count, baseline policy and collisions. */
export function PreviewResult({ preview, policy, firstBaseline, projects }: PreviewResultProps) {
  const { match_count: count, sample } = preview;
  const linked = warning(preview, "already_linked")?.count ?? 0;
  const imported = importCount(preview);

  return (
    <section
      aria-label="Wynik podglądu"
      className="mt-4 grid gap-2.5 rounded-[8px] border bg-success-surface p-[15px] text-[11px] leading-[1.8] text-success"
    >
      <p className="font-semibold">
        {count === 0
          ? "Żadne zgłoszenie nie spełnia teraz warunków."
          : `${issuesCount(count)} ${few(count) ? "spełniają" : "spełnia"} teraz warunki.`}
      </p>
      {preview.truncated ? (
        <p>
          Pokazano pierwsze {sample.length} z {count}.
        </p>
      ) : null}

      {count > 0 && firstBaseline && policy === "new_matches_only" ? (
        <p>
          {count === 1 ? "To zgłoszenie zostanie zapisane" : "Te zgłoszenia zostaną zapisane"} jako stan początkowy — bez
          powiadomień, zadań w Linear i analizy. Reguła zareaguje dopiero na nowe dopasowania.
        </p>
      ) : null}
      {firstBaseline && policy === "include_existing" ? (
        <p className="text-warning">
          Aktywacja zaimportuje {issuesCount(imported)} jako {imported === 1 ? "nową sprawę" : "nowe sprawy"}: każde dostanie
          zadanie w Linear, zaznaczone powiadomienia i płatną analizę.
        </p>
      ) : null}
      {linked > 0 ? (
        <p>
          {linked} z nich {few(linked) ? "mają" : "ma"} już sprawę w Harmony — nie powstanie duplikat, a istniejący cel w
          Linear się nie zmieni.
        </p>
      ) : null}
      <SourceConflict preview={preview} projects={projects} />

      {sample.length > 0 ? (
        <ul className="grid gap-1.5 text-foreground">
          {sample.map((issue) => {
            const url = safeUrl(issue.url);
            return (
              <li key={issue.jira_issue_id} className="rounded-[6px] border bg-card px-2.5 py-1.5 leading-[1.5]">
                <span className="flex flex-wrap items-center gap-x-2">
                  {url ? (
                    <a
                      href={url}
                      target="_blank"
                      rel="noreferrer"
                      className="inline-flex items-center gap-1 font-mono text-primary underline-offset-4 hover:underline"
                    >
                      {issue.key}
                      <ExternalLink aria-hidden className="size-3" />
                    </a>
                  ) : (
                    <span className="font-mono">{issue.key}</span>
                  )}
                  <span className="text-muted-foreground">
                    {[issue.priority_name, issue.status_name].filter(Boolean).join(" · ")}
                  </span>
                  {issue.already_linked ? (
                    <span className="rounded-[4px] bg-muted px-1.5 text-[10px] text-muted-foreground">ma już sprawę</span>
                  ) : null}
                </span>
                <span className="block">{issue.title}</span>
              </li>
            );
          })}
        </ul>
      ) : null}
      <p className="text-muted-foreground">
        Podgląd niczego nie wysłał: nie powstały wiadomości, zadania w Linear, analizy ani komentarze.
      </p>
    </section>
  );
}

interface ActivationDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  rule: AutomationRule;
  sourceLabel: string;
  preview: AutomationPreview | null;
  projects: Project[] | undefined;
  pending: boolean;
  onConfirm: () => void;
}

/** Confirmation of an activation or resume; focus-trapped by the Base UI alert dialog. */
export function ActivationDialog({
  open,
  onOpenChange,
  rule,
  sourceLabel,
  preview,
  projects,
  pending,
  onConfirm,
}: ActivationDialogProps) {
  const resume = rule.baseline_complete_at !== null;
  const title = resume ? "Wznowić regułę?" : "Aktywować regułę?";
  const confirmLabel = resume ? "Wznów regułę" : "Aktywuj regułę";

  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent className="data-[size=default]:max-w-[calc(100%-2rem)] data-[size=default]:sm:max-w-md">
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          <AlertDialogDescription render={<div />} className="grid gap-2 text-left text-xs leading-[1.6]">
            {resume ? (
              <p>
                Wznowienie odbywa się bez nowego skanu bazowego. Zgłoszenia, które zaczęły pasować w czasie pauzy, zostaną
                przyjęte jako nowe sprawy.
              </p>
            ) : rule.initial_policy === "include_existing" ? (
              <p>
                Harmony wykona pełny skan bazowy źródła {sourceLabel} i zaimportuje{" "}
                {preview ? issuesCount(importCount(preview)) : "wszystkie pasujące zgłoszenia"} jako nowe sprawy. Dla każdej
                powstanie zadanie Todo w Linear, zostaną wysłane zaznaczone powiadomienia i uruchomi się płatna analiza.
              </p>
            ) : (
              <p>
                Harmony wykona pełny skan bazowy źródła {sourceLabel}. Zgłoszenia pasujące już teraz
                {preview ? ` (według podglądu: ${preview.match_count})` : ""} zostaną zapisane jako stan początkowy — bez
                powiadomień, zadań i analizy.
              </p>
            )}
            {resume ? null : (
              <p>
                Reguła zacznie działać dopiero po poprawnym zakończeniu skanu; nieudany skan jej nie włączy. Polityki
                istniejących zgłoszeń nie będzie można potem zmienić.
              </p>
            )}
            {preview ? <SourceConflict preview={preview} projects={projects} /> : null}
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
