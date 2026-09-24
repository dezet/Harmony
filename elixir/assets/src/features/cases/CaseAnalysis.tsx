import type { ReactNode } from "react";
import { Link } from "react-router-dom";
import { ArrowRight, Check, Info, Sparkles } from "lucide-react";
import { providerErrorMessage } from "@/features/cases/useCaseActions";
import type {
  AgentWorkDetail,
  AnalysisConfidence,
  CaseAnalysis as CaseAnalysisData,
  CaseDetail,
  CaseDetailResponse,
} from "@/types/contract";

// „Analiza” tab (spec §4.4, §9.2). Everything is plain React text: the result
// never goes through raw HTML. Hypotheses are labelled as hypotheses with the
// model's confidence, and an issue-only analysis says its code claims are
// unconfirmed. Legacy agent work has no Jira analysis and none is invented.

const CONFIDENCE: Record<AnalysisConfidence, string> = { low: "niska", medium: "średnia", high: "wysoka" };

const dateTime = new Intl.DateTimeFormat("pl-PL", { dateStyle: "medium", timeStyle: "short" });
const fullDate = new Intl.DateTimeFormat("pl-PL", { dateStyle: "full", timeStyle: "long" });

function Label({ children, aside }: { children: ReactNode; aside?: ReactNode }) {
  return (
    <div className="mb-3 flex items-center gap-[7px] text-[11px] font-semibold text-primary">
      <Sparkles aria-hidden className="size-[15px]" strokeWidth={1.6} />
      {children}
      {aside ? <span className="ml-auto text-[10px] font-normal text-muted-foreground">{aside}</span> : null}
    </div>
  );
}

function StateNote({ title, children, alert = false }: { title: string; children: ReactNode; alert?: boolean }) {
  return (
    <div
      role={alert ? "alert" : undefined}
      className="rounded-[7px] border bg-background px-3.5 py-3 text-[11px] leading-[1.7] text-muted-foreground"
    >
      <p className={alert ? "font-semibold text-destructive" : "font-semibold text-foreground"}>{title}</p>
      <div className="mt-1">{children}</div>
    </div>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="mt-4">
      <h3 className="mb-1 text-[10px] font-semibold tracking-wide text-muted-foreground uppercase">{title}</h3>
      {children}
    </section>
  );
}

function When({ iso }: { iso: string }) {
  const date = new Date(iso);
  return (
    <time dateTime={iso} title={fullDate.format(date)}>
      {dateTime.format(date)}
    </time>
  );
}

function RunMetadata({ analysis }: { analysis: CaseAnalysisData }) {
  const sha = analysis.input_snapshot.repo_sha;
  const scope = analysis.result?.context_scope ?? analysis.input_snapshot.context_scope;
  return (
    <p className="mt-5 flex flex-wrap gap-x-3 gap-y-1 border-t pt-3 text-[10px] text-muted-foreground">
      <span>Wersja {analysis.version}</span>
      {analysis.completed_at ? (
        <span>
          Zakończono <When iso={analysis.completed_at} />
        </span>
      ) : null}
      <span>
        Model {analysis.model} ({analysis.effort})
      </span>
      <span>{scope === "issue_and_repository" ? "Kontekst: zgłoszenie i repozytorium" : "Kontekst: tylko zgłoszenie"}</span>
      {sha ? <span className="font-mono">SHA {sha.slice(0, 12)}</span> : null}
    </p>
  );
}

function AnalysisResultView({ analysis }: { analysis: CaseAnalysisData }) {
  const result = analysis.result!;
  const [nextStep, ...laterSteps] = result.next_steps;

  return (
    <div>
      <Label aside={`wersja ${analysis.version}`}>Ustalenia agenta</Label>
      {result.needs_input ? (
        <p className="mb-3 rounded-[7px] bg-warning-surface px-3 py-2 text-[11px] text-warning">
          Do zakończenia analizy potrzebne są dodatkowe dane.
        </p>
      ) : null}
      <p className="mb-[18px] text-[13px] leading-[1.8] whitespace-pre-line text-foreground">{result.summary}</p>

      {result.facts.length > 0 ? (
        <ul aria-label="Fakty">
          {result.facts.map((fact, index) => (
            <li key={index} className="flex items-start gap-[9px] border-t py-3 text-[11px] leading-[1.65]">
              <Check aria-hidden className="mt-0.5 size-[15px] shrink-0 text-success" strokeWidth={1.8} />
              <div className="min-w-0">
                <p className="font-semibold whitespace-pre-line text-foreground">{fact.text}</p>
                <p className="mt-0.5 break-words text-muted-foreground">Źródło: {fact.source}</p>
              </div>
            </li>
          ))}
        </ul>
      ) : null}

      {result.hypotheses.length > 0 ? (
        <ul aria-label="Hipotezy">
          {result.hypotheses.map((hypothesis, index) => (
            <li key={index} className="flex items-start gap-[9px] border-t py-3 text-[11px] leading-[1.65]">
              <Info aria-hidden className="mt-0.5 size-[15px] shrink-0 text-warning" strokeWidth={1.8} />
              <div className="min-w-0">
                <p className="mb-1 flex flex-wrap gap-1.5 text-[10px]">
                  <span className="rounded-[5px] bg-warning-surface px-1.5 py-0.5 font-[550] text-warning">Hipoteza</span>
                  <span className="rounded-[5px] border px-1.5 py-0.5 text-muted-foreground">
                    Pewność: {CONFIDENCE[hypothesis.confidence]}
                  </span>
                </p>
                <p className="font-semibold whitespace-pre-line text-foreground">{hypothesis.text}</p>
                {hypothesis.evidence.length > 0 ? (
                  <p className="mt-0.5 break-words text-muted-foreground">Przesłanki: {hypothesis.evidence.join(", ")}</p>
                ) : null}
              </div>
            </li>
          ))}
        </ul>
      ) : null}
      <p className="border-t pt-2 text-[10px] leading-[1.6] text-muted-foreground">
        Hipotezy wymagają potwierdzenia — to nie jest rozstrzygnięta diagnoza.
        {result.context_scope === "issue_only"
          ? " Analiza objęła tylko treść zgłoszenia; twierdzenia o kodzie nie zostały sprawdzone w repozytorium."
          : null}
      </p>

      {result.missing_data.length > 0 ? (
        <Section title="Brakujące dane">
          <ul aria-label="Brakujące dane" className="list-disc space-y-1 pl-5 text-[11px] leading-[1.65] text-foreground">
            {result.missing_data.map((item, index) => (
              <li key={index} className="whitespace-pre-line">
                {item}
              </li>
            ))}
          </ul>
        </Section>
      ) : null}

      {nextStep ? (
        <div className="mt-[13px] flex items-start gap-2.5 rounded-[7px] border bg-background px-3.5 py-[13px]">
          <ArrowRight aria-hidden className="size-4 shrink-0 text-primary" strokeWidth={1.6} />
          <div className="min-w-0">
            <h3 className="text-sm font-semibold text-foreground">Następny krok</h3>
            <p className="mt-[5px] text-[11px] leading-[1.7] whitespace-pre-line text-muted-foreground">{nextStep}</p>
            {laterSteps.length > 0 ? (
              <ul aria-label="Kolejne kroki" className="mt-2 list-disc space-y-1 pl-5 text-[11px] leading-[1.7] text-muted-foreground">
                {laterSteps.map((step, index) => (
                  <li key={index} className="whitespace-pre-line">
                    {step}
                  </li>
                ))}
              </ul>
            ) : null}
          </div>
        </div>
      ) : null}

      <RunMetadata analysis={analysis} />
    </div>
  );
}

function JiraAnalysis({ detail }: { detail: CaseDetail }) {
  const { analysis } = detail;

  if (!analysis) {
    if (detail.case.analysis_status === "running") {
      return (
        <div>
          <Label aside="w toku">Agent analizuje zgłoszenie</Label>
          <StateNote title="Analiza w toku">Wynik pojawi się tutaj po zakończeniu analizy i jej walidacji.</StateNote>
        </div>
      );
    }
    if (detail.case.analysis_status === "failed") {
      return (
        <StateNote alert title="Analiza zakończyła się błędem">
          Wynik nie został zapisany. Szczegóły są w historii sprawy.
        </StateNote>
      );
    }
    return (
      <StateNote title="Analiza oczekuje w kolejce">
        Analiza rozpocznie się, gdy będzie dostępne miejsce dla agenta. Do tego czasu nie ma ustaleń.
      </StateNote>
    );
  }

  if (analysis.status === "failed" || !analysis.result) {
    return (
      <div>
        <StateNote alert title="Analiza zakończyła się błędem">
          <p>{providerErrorMessage(analysis.error_code) ?? "Analiza nie zwróciła poprawnego wyniku."}</p>
          <p>Błędny wynik nie jest publikowany w Jira. Szczegóły są w historii sprawy.</p>
        </StateNote>
        <RunMetadata analysis={analysis} />
      </div>
    );
  }

  return <AnalysisResultView analysis={analysis} />;
}

function LegacyAnalysis({ detail }: { detail: AgentWorkDetail }) {
  const { project, linear } = detail.case;
  const slug = encodeURIComponent(project.slug);

  return (
    <StateNote title="Brak analizy Jira">
      <p>To istniejąca praca agenta, bez zgłoszenia Jira. Harmony nie tworzy dla niej analizy.</p>
      <p className="mt-2 flex flex-wrap gap-4">
        {linear ? (
          <Link className="text-primary underline underline-offset-4" to={`/projects/${slug}/runs/${encodeURIComponent(linear.identifier)}`}>
            Historia i dowody przebiegu
          </Link>
        ) : null}
        <Link className="text-primary underline underline-offset-4" to={`/projects/${slug}?tab=evidence`}>
          Dowody projektu
        </Link>
      </p>
    </StateNote>
  );
}

export function CaseAnalysis({ detail }: { detail: CaseDetailResponse }) {
  if (detail.case.kind === "agent_work" || detail.version === null) {
    return <LegacyAnalysis detail={detail as AgentWorkDetail} />;
  }
  return <JiraAnalysis detail={detail as CaseDetail} />;
}
