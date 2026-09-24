import { useEffect, useId, useState } from "react";
import { Link } from "react-router-dom";
import { Clock, Loader2, Plus, TriangleAlert } from "lucide-react";
import { Button, buttonVariants } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { useProjects } from "@/features/projects/useProjects";
import { ActivationDialog } from "@/features/automations/AutomationPreview";
import { formatInterval } from "@/features/automations/automationSchema";
import {
  automationErrorMessage,
  formatRuleTime,
  ruleErrorMessage,
  ruleState,
  RULE_STATE_LABEL,
  useActivateAutomation,
  useAutomationList,
  useCheckAutomation,
  useJiraPriorities,
  usePauseAutomation,
  type RuleState,
} from "@/features/automations/useAutomations";
import type { AutomationRule, Project } from "@/types/contract";

// Rule list of layout A (spec §4.6): project, source, priorities, frequency,
// switch, last success, next check and error of every rule. The switch pauses
// at once and resumes only after a confirmation; both show the rule the
// backend returned, never an optimistic state. The first activation happens in
// the editor, next to the dry run.

const actionButton =
  "h-auto min-h-[35px] gap-[7px] rounded-[7px] px-3 py-[9px] text-[11px] font-[550] leading-[1.3] [&_svg:not([class*='size-'])]:size-3.5";
const smallButton = "h-auto min-h-[30px] rounded-[7px] px-[9px] py-1.5 text-[11px] font-[550]";

const STATE_TONE: Record<RuleState, string> = {
  active: "bg-success-surface text-success",
  activating: "bg-accent text-primary",
  error: "bg-destructive-surface text-destructive",
  paused: "bg-warning-surface text-warning",
  draft: "bg-muted text-muted-foreground",
};

function PriorityNames({ rule }: { rule: AutomationRule }) {
  const priorities = useJiraPriorities(rule.jira_connection_id);
  const names = rule.priority_ids.map(
    (id) => priorities.data?.find((entry) => entry.id === id)?.name ?? `ID ${id}`,
  );
  return <>{names.join(", ")}</>;
}

function projectName(projects: Project[] | undefined, id: string): string {
  const project = projects?.find((entry) => entry.id === id);
  return project ? project.display_name || project.slug : "Nieznany projekt";
}

function RuleRow({ rule, projects }: { rule: AutomationRule; projects: Project[] | undefined }) {
  const titleId = useId();
  const pause = usePauseAutomation(rule.id);
  const activate = useActivateAutomation(rule.id);
  const check = useCheckAutomation(rule.id);
  const [confirming, setConfirming] = useState(false);

  const state = ruleState(rule);
  const on = state === "active" || state === "activating";
  const resumable = !on && rule.baseline_complete_at !== null;
  const failure = pause.error ?? activate.error;
  const error = ruleErrorMessage(rule.last_error_code);
  const source = `${rule.source_type === "board" ? "Tablica" : "Zapisany filtr"} · ID ${rule.source_id}`;

  const toggle = () => {
    pause.reset();
    activate.reset();
    if (on) pause.mutate(rule.config_version);
    else setConfirming(true);
  };

  return (
    <li aria-labelledby={titleId} className="grid gap-2.5 rounded-[10px] border bg-card px-5 py-4 shadow-[0_1px_2px_#20242f0a]">
      <div className="flex items-start justify-between gap-4 max-[600px]:flex-wrap">
        <div className="min-w-0">
          <Link id={titleId} to={`/automations/${rule.id}`} className="text-[14px] font-semibold hover:text-primary hover:underline">
            {rule.name}
          </Link>
          <p className="mt-1 text-[11px] leading-[1.6] text-muted-foreground">
            {projectName(projects, rule.project_id)} · {source} · Priorytety: <PriorityNames rule={rule} /> · co{" "}
            {formatInterval(rule.interval_seconds)}
          </p>
        </div>
        <div className="flex shrink-0 items-center gap-2 text-[11px]">
          {on || resumable ? (
            <button
              type="button"
              role="switch"
              aria-checked={on}
              aria-label={`Reguła ${rule.name} aktywna`}
              disabled={pause.isPending || activate.isPending}
              onClick={toggle}
              className={cn(
                "inline-flex h-5 w-[34px] items-center rounded-full p-[3px] outline-none focus-visible:ring-2 focus-visible:ring-ring/50 disabled:cursor-not-allowed disabled:opacity-60",
                on ? "bg-primary" : "bg-muted-foreground",
              )}
            >
              <span
                aria-hidden
                className={cn("block size-3.5 rounded-full bg-card transition-transform motion-reduce:transition-none", on ? "translate-x-3.5" : null)}
              />
            </button>
          ) : null}
          <span className={cn("rounded-[5px] px-2 py-0.5 font-[550]", STATE_TONE[state])}>{RULE_STATE_LABEL[state]}</span>
        </div>
      </div>

      <div className="flex flex-wrap gap-x-5 gap-y-1 text-[11px] text-muted-foreground">
        <p>Ostatni sukces: {formatRuleTime(rule.last_success_at)}</p>
        <p>Następne sprawdzenie: {formatRuleTime(rule.next_poll_at)}</p>
      </div>

      {error ? (
        <p className="flex items-start gap-1.5 text-[11px] leading-[1.5] text-destructive">
          <TriangleAlert aria-hidden className="mt-px size-3 shrink-0" strokeWidth={1.8} />
          {error}
        </p>
      ) : null}
      {failure ? (
        <p role="alert" className="text-[11px] leading-[1.5] text-destructive">
          {automationErrorMessage(failure)}
        </p>
      ) : null}

      <div className="flex flex-wrap items-center gap-3">
        {rule.enabled ? (
          <Button
            type="button"
            variant="outline"
            size="sm"
            className={cn(smallButton, "bg-card")}
            disabled={check.isPending}
            onClick={() => check.mutate()}
          >
            {check.isPending ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : <Clock aria-hidden />}
            Sprawdź teraz
          </Button>
        ) : null}
        {state === "draft" || (state === "error" && !resumable) ? (
          <Link to={`/automations/${rule.id}`} className="text-[11px] text-primary underline underline-offset-4">
            Aktywuj w edytorze
          </Link>
        ) : null}
        <p role="status" aria-live="polite" className={cn("text-[11px]", check.isError ? "text-destructive" : "text-success")}>
          {check.isError
            ? automationErrorMessage(check.error)
            : check.isSuccess
              ? "Zakolejkowano sprawdzenie. Nowe sprawy pojawią się po zakończeniu skanu."
              : ""}
        </p>
      </div>

      <ActivationDialog
        open={confirming}
        onOpenChange={setConfirming}
        rule={rule}
        sourceLabel={source}
        preview={null}
        projects={projects}
        pending={activate.isPending}
        onConfirm={() => activate.mutate(rule.config_version, { onSettled: () => setConfirming(false) })}
      />
    </li>
  );
}

export function AutomationsPage() {
  const list = useAutomationList();
  const projects = useProjects();

  useEffect(() => {
    document.title = "Automatyzacje — Harmony";
  }, []);

  const rules = list.data?.pages.flatMap((page) => page.items) ?? [];

  return (
    <div>
      <div className="mb-[23px] flex items-center justify-between gap-[18px] max-[600px]:flex-wrap max-[600px]:gap-2.5">
        <div className="min-w-0">
          <h1 className="text-title max-[1150px]:text-[26px] max-[600px]:text-[27px]">Automatyzacje</h1>
          <p className="mt-2 text-xs leading-[1.6] text-muted-foreground">Reguły sprawdzania zgłoszeń Jira i ich stan.</p>
        </div>
        <Link to="/automations/new" className={cn(buttonVariants(), actionButton, "max-[600px]:w-full")}>
          <Plus aria-hidden strokeWidth={1.6} />
          Nowa reguła
        </Link>
      </div>

      {list.isPending ? (
        <div aria-label="Wczytywanie reguł" className="grid gap-3">
          <Skeleton className="h-[108px] w-full rounded-[10px]" />
          <Skeleton className="h-[108px] w-full rounded-[10px]" />
        </div>
      ) : list.isError && !list.data ? (
        <div role="alert" className="grid justify-items-start gap-2 rounded-[10px] border bg-card p-5 text-xs">
          <p className="font-semibold text-destructive">Nie udało się wczytać reguł.</p>
          <p className="text-muted-foreground">{automationErrorMessage(list.error)}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => void list.refetch()}>
            Spróbuj ponownie
          </Button>
        </div>
      ) : rules.length === 0 ? (
        <div className="grid justify-items-center gap-2 rounded-[10px] border bg-card px-6 py-10 text-center text-xs leading-[1.8] text-muted-foreground">
          <p className="font-semibold text-foreground">Nie masz jeszcze reguł Jira</p>
          <p>Reguła określa, które zgłoszenia Harmony ma wykrywać, dokąd je przekazać i kogo powiadomić.</p>
          <Link to="/automations/new" className={cn(buttonVariants({ variant: "outline", size: "sm" }))}>
            Utwórz pierwszą regułę
          </Link>
        </div>
      ) : (
        <>
          <ul className="grid gap-3">
            {rules.map((rule) => (
              <RuleRow key={rule.id} rule={rule} projects={projects.data} />
            ))}
          </ul>
          {list.isFetchNextPageError ? (
            <p role="alert" className="mt-3 text-[11px] text-destructive">
              Nie udało się wczytać kolejnych reguł.
            </p>
          ) : null}
          {list.hasNextPage ? (
            <Button
              type="button"
              variant="outline"
              className={cn(actionButton, "mt-3 bg-card")}
              disabled={list.isFetchingNextPage}
              onClick={() => void list.fetchNextPage()}
            >
              {list.isFetchingNextPage ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : null}
              Wczytaj więcej reguł
            </Button>
          ) : null}
        </>
      )}
    </div>
  );
}
