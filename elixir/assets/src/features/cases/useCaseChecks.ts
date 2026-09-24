import { useMutation, useQueryClient } from "@tanstack/react-query";
import { ApiError, checkAutomations, requestRefresh } from "@/lib/api";
import type { AutomationBulkCheck } from "@/types/contract";

// "Sprawdź teraz" of the Case Center header (spec §4.4): queues the active
// rules of the scope plus the existing Linear refresh. Neither is reported as
// a finished synchronization. The rule schedule itself lives with the rule
// hooks in `features/automations/useAutomations.ts`.

export type CheckTone = "success" | "warning" | "error";

export interface CheckOutcome {
  tone: CheckTone;
  message: string;
}

const SKIP_REASONS: Record<string, string> = {
  scan_in_progress: "sprawdzenie już trwa",
  scan_capacity: "wykorzystano limit równoległych sprawdzeń",
  rule_not_active: "reguła nie jest aktywna",
  not_found: "reguła nie istnieje",
  effects_disabled: "efekty zewnętrzne są wyłączone",
  intake_disabled: "pobieranie zgłoszeń z Jira jest wyłączone",
  jira_connection_disabled: "połączenie Jira jest wyłączone",
  credentials_missing: "brak poświadczeń połączenia",
  scan_failed: "nie udało się rozpocząć sprawdzenia",
};

const CONFLICTS: Record<string, string> = {
  intake_disabled: "Pobieranie zgłoszeń z Jira jest wyłączone w konfiguracji.",
  effects_disabled: "Efekty zewnętrzne są wyłączone w konfiguracji.",
  scan_in_progress: "Sprawdzenie już trwa.",
  scan_capacity: "Wykorzystano limit równoległych sprawdzeń. Spróbuj za chwilę.",
};

function reason(code: string): string {
  return SKIP_REASONS[code] ?? `nieznany powód (${code})`;
}

function rulesLabel(count: number): string {
  if (count === 1) return "reguły Jira";
  return "reguł Jira";
}

function describeAccepted(result: AutomationBulkCheck): CheckOutcome {
  const accepted = result.accepted_rule_ids.length;
  const reasons = [...new Set(result.skipped.map((skip) => reason(skip.code)))].join(", ");

  if (accepted > 0) {
    const skipped = result.skipped.length > 0 ? ` Pominięto ${result.skipped.length}: ${reasons}.` : "";
    return {
      tone: "success",
      message: `Zakolejkowano sprawdzenie ${accepted} ${rulesLabel(accepted)}.${skipped} Nowe sprawy pojawią się po zakończeniu skanu.`,
    };
  }
  if (result.skipped.length === 0) {
    return { tone: "warning", message: "Brak reguł Jira do sprawdzenia w tym zakresie." };
  }
  return { tone: "warning", message: `Nie zakolejkowano sprawdzenia: ${reasons}.` };
}

function describeRejected(error: unknown): CheckOutcome {
  if (error instanceof ApiError) {
    if (error.status === 409) {
      return { tone: "warning", message: CONFLICTS[error.code] ?? `Sprawdzenie odrzucone: ${reason(error.code)}.` };
    }
    if (error.status === 503) {
      return { tone: "error", message: "Harmonogram sprawdzeń jest niedostępny. Spróbuj ponownie później." };
    }
    if (error.status === 403) {
      return { tone: "error", message: "Sesja wygasła. Odświeżono zabezpieczenie — spróbuj ponownie." };
    }
  }
  return { tone: "error", message: "Nie udało się zakolejkować sprawdzenia. Spróbuj ponownie." };
}

export function describeCheck(
  check: PromiseSettledResult<AutomationBulkCheck>,
  refresh: PromiseSettledResult<unknown>,
): CheckOutcome {
  const outcome = check.status === "fulfilled" ? describeAccepted(check.value) : describeRejected(check.reason);
  const linear =
    refresh.status === "fulfilled"
      ? " Zlecono odświeżenie Linear."
      : " Nie udało się zlecić odświeżenia Linear.";
  return { ...outcome, message: outcome.message + linear };
}

/** "Sprawdź teraz": never optimistic, always settles with a described outcome. */
export function useCheckNow() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async (projectId: string | undefined): Promise<CheckOutcome> => {
      const [check, refresh] = await Promise.allSettled([
        checkAutomations(projectId ? { project: projectId } : {}),
        requestRefresh(),
      ]);
      return describeCheck(check, refresh);
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ["automations"] }),
  });
}
