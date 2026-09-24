import { useId, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { ElapsedTime } from "@/components/ElapsedTime";
import { formatRuleTime } from "@/features/automations/useAutomations";
import { cn } from "@/lib/utils";
import type { IntakeDiagnostics as IntakeDiagnosticsPayload, IntakeOperation, IntakeRuleScan } from "@/types/contract";

// Jira intake metrics of spec §12, all aggregated in PostgreSQL by the backend
// (StatePayload.intake). Shows counts, times and safe error codes only; the
// raw codes stay verbatim so an operator can look them up.

const OPERATION_LABEL: Record<IntakeOperation, string> = {
  linear_create: "Utworzenie w Linear",
  analysis: "Analiza",
  jira_comment: "Komentarz Jira",
  email: "E-mail",
  sms: "SMS",
};

const QUEUE_COLUMNS = [
  ["pending", "Oczekuje"],
  ["retry_wait", "Ponowienie"],
  ["running", "W toku"],
  ["paused", "Wstrzymane"],
  ["unknown", "Nieznany wynik"],
  ["failed", "Nieudane"],
] as const;

const SCAN_STATUS: Record<string, string> = {
  succeeded: "udany",
  failed: "nieudany",
  cancelled: "anulowany",
  running: "w toku",
  pending: "oczekuje",
};

const number = new Intl.NumberFormat("pl-PL");
const seconds = new Intl.NumberFormat("pl-PL", { maximumFractionDigits: 1 });

function Metric({ label, value, detail, alert }: { label: string; value: ReactNode; detail?: ReactNode; alert?: boolean }) {
  const id = useId();
  return (
    <div role="group" aria-labelledby={id} className="grid content-start gap-1 rounded-[10px] border bg-card p-4">
      <span id={id} className="text-[11px] text-muted-foreground">
        {label}
      </span>
      <span className={cn("text-[22px] font-semibold tabular-nums", alert && "text-destructive")}>{value}</span>
      {detail ? <span className="text-[11px] text-muted-foreground">{detail}</span> : null}
    </div>
  );
}

function Switch({ on, children }: { on: boolean; children: ReactNode }) {
  return (
    <li
      className={cn(
        "rounded-[5px] px-[7px] py-1 text-[10px] leading-[1.25] font-[550]",
        on ? "bg-success-surface text-success" : "bg-muted text-muted-foreground",
      )}
    >
      {children}
    </li>
  );
}

function scanText(scan: IntakeRuleScan | null): string {
  if (!scan) return "—";
  const duration = scan.duration_ms == null ? "—" : `${seconds.format(scan.duration_ms / 1000)} s`;
  return `${duration} · ${SCAN_STATUS[scan.status] ?? scan.status}`;
}

const cell = "px-2 py-1.5 text-left tabular-nums";
const head = "px-2 py-1.5 text-left text-[11px] font-[550] text-muted-foreground";

export function IntakeDiagnostics({ value }: { value: IntakeDiagnosticsPayload | undefined }) {
  const titleId = useId();

  return (
    <section aria-labelledby={titleId} className="grid gap-4 rounded-[10px] border bg-card p-[23px] max-[600px]:p-[18px]">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 id={titleId} className="text-[17px] font-semibold">
          Intake Jira
        </h2>
        {value ? (
          <span className="text-[11px] text-muted-foreground">Stan z {formatRuleTime(value.generated_at)}</span>
        ) : null}
      </div>

      {!value ? (
        <p className="text-xs text-muted-foreground">
          Dane diagnostyczne intake są niedostępne. Sprawdź połączenie z bazą danych i odśwież widok.
        </p>
      ) : (
        <>
          <ul aria-label="Przełączniki intake" className="flex flex-wrap gap-2">
            <Switch on={value.switches.intake_enabled}>Intake: {value.switches.intake_enabled ? "włączony" : "wyłączony"}</Switch>
            <Switch on={value.switches.effects_enabled}>
              Efekty zewnętrzne: {value.switches.effects_enabled ? "włączone" : "wyłączone"}
            </Switch>
            <Switch on={value.switches.analysis_enabled}>Analiza: {value.switches.analysis_enabled ? "włączona" : "wyłączona"}</Switch>
          </ul>

          <div className="grid grid-cols-5 gap-3 max-[1150px]:grid-cols-3 max-[600px]:grid-cols-2">
            <Metric label="Zaległe efekty" value={number.format(value.backlog.total)} detail="oczekujące, do ponowienia i wstrzymane" />
            <Metric
              label="Najstarszy oczekujący"
              value={value.backlog.oldest_waiting_at ? <ElapsedTime since={value.backlog.oldest_waiting_at} /> : "—"}
              detail={value.backlog.oldest_waiting_at ? "temu" : "brak oczekujących"}
            />
            <Metric label="Nieznany wynik" value={number.format(value.unknown)} alert={value.unknown > 0} />
            <Metric
              label="Wygasłe dzierżawy"
              value={number.format(value.stale_leases.deliveries + value.stale_leases.rules)}
              detail={`efekty: ${value.stale_leases.deliveries} · reguły: ${value.stale_leases.rules}`}
              alert={value.stale_leases.deliveries + value.stale_leases.rules > 0}
            />
            <Metric
              label="Pula analizy"
              value={`${value.analysis.active} / ${value.analysis.limit}`}
              detail={`w kolejce: ${value.analysis.queued}`}
            />
          </div>

          {value.unknown > 0 ? (
            <p role="status" className="rounded-[7px] bg-warning-surface px-3 py-2 text-xs text-warning">
              Efekty z nieznanym wynikiem ({value.unknown}) nie są ponawiane automatycznie. Sprawdź u dostawcy, czy
              wiadomość lub komentarz dotarły, zanim ponowisz — inaczej grozi duplikat.
            </p>
          ) : null}

          <div className="overflow-x-auto">
            <table aria-label="Kolejki efektów" className="w-full min-w-[560px] text-xs">
              <thead>
                <tr className="border-b">
                  <th scope="col" className={head}>
                    Efekt
                  </th>
                  {QUEUE_COLUMNS.map(([key, label]) => (
                    <th key={key} scope="col" className={head}>
                      {label}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {value.queues.map((queue) => (
                  <tr key={queue.operation} className="border-b last:border-0">
                    <th scope="row" className={cn(cell, "font-[550]")}>
                      {OPERATION_LABEL[queue.operation] ?? queue.operation}
                    </th>
                    {QUEUE_COLUMNS.map(([key]) => (
                      <td key={key} className={cn(cell, key === "unknown" && queue.unknown > 0 && "text-destructive")}>
                        {number.format(queue[key])}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="grid gap-2">
            <h3 className="text-sm font-semibold">Błędy kanałów</h3>
            {value.channel_errors.length === 0 ? (
              <p className="text-xs text-muted-foreground">Brak błędów kanałów.</p>
            ) : (
              <ul aria-label="Błędy kanałów" className="grid gap-1 text-xs">
                {value.channel_errors.map((error) => (
                  <li key={`${error.operation}-${error.error_code}`} className="flex flex-wrap gap-2">
                    <span className="font-[550]">{OPERATION_LABEL[error.operation] ?? error.operation}</span>
                    <span className="font-mono text-muted-foreground">{error.error_code}</span>
                    <span className="tabular-nums">× {number.format(error.count)}</span>
                  </li>
                ))}
              </ul>
            )}
          </div>

          <div className="grid gap-2">
            <h3 className="text-sm font-semibold">Reguły Jira</h3>
            {value.rules.length === 0 ? (
              <p className="text-xs text-muted-foreground">Brak reguł Jira.</p>
            ) : (
              <div className="overflow-x-auto">
                <table aria-label="Reguły Jira" className="w-full min-w-[720px] text-xs">
                  <thead>
                    <tr className="border-b">
                      {["Reguła", "Projekt", "Stan", "Ostatni sukces", "Ostatni skan", "Następne sprawdzenie", "Błąd"].map((label) => (
                        <th key={label} scope="col" className={head}>
                          {label}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {value.rules.map((rule) => (
                      <tr key={rule.id} className="border-b last:border-0">
                        <td className={cell}>
                          <Link to={`/automations/${rule.id}`} className="font-[550] underline-offset-2 hover:underline">
                            {rule.name}
                          </Link>
                        </td>
                        <td className={cell}>{rule.project.name}</td>
                        <td className={cell}>{rule.enabled ? "Aktywna" : "Wyłączona"}</td>
                        <td className={cell}>{rule.last_success_at ? formatRuleTime(rule.last_success_at) : "Nigdy"}</td>
                        <td className={cell}>
                          {scanText(rule.last_scan)}
                          {rule.last_scan?.error_code ? (
                            <span className="ml-1 font-mono text-destructive">{rule.last_scan.error_code}</span>
                          ) : null}
                        </td>
                        <td className={cell}>{formatRuleTime(rule.next_poll_at)}</td>
                        <td className={cn(cell, "font-mono")}>{rule.last_error_code ?? "—"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </>
      )}
    </section>
  );
}
