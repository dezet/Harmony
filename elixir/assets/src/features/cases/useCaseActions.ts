import { useSyncExternalStore } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { acknowledgeCase, ApiError, approveRepair, reanalyzeCase, retryDelivery } from "@/lib/api";
import { CASE_EVENTS_KEY, CASE_KEY } from "@/lib/queryClient";
import { useIntakeChannel } from "@/features/cases/useIntakeChannel";
import type { DeliveryOperation, DeliveryStatus } from "@/types/contract";

// Operator decisions on one case (spec §4.4, §8.2, §9, §11.2). No optimistic
// success: every mutation waits for the backend, then the case, its history
// and every list are refetched, also after a failure, so a 409 shows the
// current state. A CSRF 403 is never repeated automatically (api.ts refreshes
// the token); the operator repeats the action. Whether an action is available
// comes only from the backend `actions`; the UI translates the reason code.

function useCaseInvalidation(ref: string) {
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: CASE_KEY(ref) }),
      queryClient.invalidateQueries({ queryKey: CASE_EVENTS_KEY(ref) }),
      queryClient.invalidateQueries({ queryKey: ["cases"] }),
    ]);
}

export function useAcknowledgeCase(ref: string) {
  const invalidate = useCaseInvalidation(ref);
  return useMutation({
    mutationFn: (expectedVersion: number) => acknowledgeCase(ref, { expected_version: expectedVersion }),
    onSettled: invalidate,
  });
}

export function useApproveRepair(ref: string) {
  const invalidate = useCaseInvalidation(ref);
  return useMutation({
    mutationFn: (input: { expectedVersion: number; analysisVersion: number }) =>
      approveRepair(ref, {
        expected_version: input.expectedVersion,
        analysis_version: input.analysisVersion,
        confirmed: true,
      }),
    onSettled: invalidate,
  });
}

export function useReanalyzeCase(ref: string) {
  const invalidate = useCaseInvalidation(ref);
  return useMutation({
    mutationFn: (expectedVersion: number) => reanalyzeCase(ref, { expected_version: expectedVersion, confirmed: true }),
    onSettled: invalidate,
  });
}

/** Retry of one delivery of the case, never of the whole workflow. */
export function useRetryDelivery(ref: string) {
  const invalidate = useCaseInvalidation(ref);
  return useMutation({
    mutationFn: (input: { id: string; expectedStatus: DeliveryStatus; confirmDuplicateRisk: boolean }) =>
      retryDelivery(
        input.id,
        input.confirmDuplicateRisk
          ? { expected_status: input.expectedStatus, confirm_duplicate_risk: true }
          : { expected_status: input.expectedStatus },
      ),
    onSettled: invalidate,
  });
}

function subscribeOnline(listener: () => void): () => void {
  window.addEventListener("online", listener);
  window.addEventListener("offline", listener);
  return () => {
    window.removeEventListener("online", listener);
    window.removeEventListener("offline", listener);
  };
}

/** Offline (browser or intake channel): keep the last data, disable mutations (spec §4.5). */
export function useActionsOffline(): boolean {
  const channel = useIntakeChannel();
  const online = useSyncExternalStore(subscribeOnline, () => navigator.onLine, () => true);
  return !online || channel === "offline" || channel === "reconnecting";
}

// ─── Vocabulary ────────────────────────────────────────────────────────────

export const OPERATION_LABEL: Record<DeliveryOperation, string> = {
  linear_create: "Zadanie w Linear",
  email: "E-mail",
  sms: "SMS",
  analysis: "Analiza",
  jira_comment: "Komentarz w Jira",
};

/** Accusative form for „Ponów …”. */
export const OPERATION_RETRY_LABEL: Record<DeliveryOperation, string> = {
  linear_create: "Ponów utworzenie zadania w Linear",
  email: "Ponów e-mail",
  sms: "Ponów SMS",
  analysis: "Ponów analizę",
  jira_comment: "Ponów publikację komentarza",
};

export const DELIVERY_STATUS_LABEL: Record<DeliveryStatus, string> = {
  pending: "Oczekuje",
  running: "W toku",
  retry_wait: "Czeka na ponowienie",
  succeeded: "Zakończono",
  failed: "Błąd",
  unknown: "Wynik nieznany",
  paused: "Wstrzymano",
};

// Backend codes shared by `actions.*.reason` and error envelopes (T17
// IntakePresenter, Intake.Actions.availability/2).
const CODE_MESSAGES: Record<string, string> = {
  already_acknowledged: "Sprawa została już przyjęta.",
  unsupported_case_kind: "Akcja dotyczy tylko spraw z Jira.",
  effects_disabled: "Efekty zewnętrzne są wyłączone w konfiguracji Harmony. Nic nie zostało wysłane.",
  intake_disabled: "Obsługa zgłoszeń Jira jest wyłączona w konfiguracji Harmony.",
  repair_already_approved: "Naprawa została już zatwierdzona.",
  analysis_not_ready: "Analiza nie jest jeszcze gotowa.",
  analysis_not_published: "Komentarz z analizą nie został jeszcze opublikowany w Jira.",
  linear_not_confirmed: "Zadanie w Linear nie zostało jeszcze potwierdzone.",
  analysis_profile_unavailable: "Profil analizy nie jest skonfigurowany.",
  confirmation_required: "Akcja wymaga potwierdzenia.",
  stale_version: "Sprawa zmieniła się w międzyczasie. Wczytaliśmy aktualny stan — sprawdź go i spróbuj ponownie.",
  status_mismatch: "Stan wysyłki zmienił się w międzyczasie. Wczytaliśmy aktualny stan — sprawdź go i spróbuj ponownie.",
  not_retryable: "Tej wysyłki nie można teraz ponowić.",
  dependency_paused: "Połączenie tego kanału jest wyłączone.",
  analysis_retry_requires_new_version: "Analizę ponawia się, zlecając nową wersję.",
  effect_already_applied: "Dostawca już wykonał ten efekt; ponowienie nie jest potrzebne.",
  reconciliation_required: "Wysyłka wymaga ręcznego uzgodnienia stanu u dostawcy przed ponowieniem.",
  reconciliation_failed: "Nie udało się odczytać stanu u dostawcy. Spróbuj ponownie później.",
  connection_disabled: "Połączenie jest wyłączone.",
  jira_connection_disabled: "Połączenie z Jira jest wyłączone.",
  credentials_missing: "Połączenie nie ma zapisanych poświadczeń.",
  not_found: "Nie znaleziono sprawy albo wysyłki. Odśwież widok.",
  action_unavailable: "Akcja jest chwilowo niedostępna. Spróbuj ponownie później.",
  csrf_invalid: "Zabezpieczenie sesji wygasło i zostało odnowione. Akcja nie została wykonana — kliknij ponownie.",
  origin_rejected: "Serwer odrzucił żądanie z tego adresu. Akcja nie została wykonana — odśwież stronę i kliknij ponownie.",
  csrf_unavailable: "Nie udało się pobrać zabezpieczenia sesji. Akcja nie została wykonana — kliknij ponownie.",
};

const GENERIC_REASON = "Akcja jest teraz niedostępna.";
const GENERIC_ERROR = "Nie udało się wykonać akcji. Spróbuj ponownie później.";
const NETWORK_ERROR = "Brak odpowiedzi serwera. Akcja mogła nie zostać wykonana — odśwież widok i sprawdź stan.";

/** Polish text of a refusal reason; an unknown code gets a generic text, never the code. */
export function reasonMessage(reason: string | null): string {
  return (reason && CODE_MESSAGES[reason]) || GENERIC_REASON;
}

/** Polish text of a failed mutation. */
export function actionErrorMessage(error: unknown): string {
  if (error instanceof ApiError) return CODE_MESSAGES[error.code] ?? GENERIC_ERROR;
  return NETWORK_ERROR;
}

// Error codes stored on deliveries, analyses and publications.
const PROVIDER_ERRORS: Record<string, string> = {
  lease_expired: "Przerwano próbę w trakcie wysyłki.",
  connection_required: "Brak skonfigurowanego połączenia.",
  analysis_timeout: "Analiza przekroczyła limit czasu.",
  analysis_attempt_limit_reached: "Wyczerpano liczbę prób analizy tej wersji.",
  analysis_backend_failed: "Silnik analizy zwrócił błąd.",
  analysis_context_failed: "Nie udało się przygotować kontekstu analizy.",
  analysis_result_persist_failed: "Nie udało się zapisać wyniku analizy.",
  analysis_failed: "Analiza nie zwróciła poprawnego wyniku.",
  analysis_profile_unavailable: "Profil analizy nie jest skonfigurowany.",
  jira_comment_permission_denied: "Jira odmówiła dodania komentarza (brak uprawnień).",
  jira_comment_rejected: "Jira odrzuciła komentarz.",
  jira_comment_outcome_unknown: "Nie wiadomo, czy Jira przyjęła komentarz.",
  jira_connection_unavailable: "Połączenie z Jira jest niedostępne.",
  jira_rate_limited: "Jira ograniczyła liczbę zapytań.",
  linear_request_failed: "Linear odrzucił żądanie.",
  linear_transport_error: "Brak połączenia z Linear.",
  sms_auth_failed: "SMSAPI odrzuciło poświadczenia.",
  sms_credentials_missing: "Połączenie SMSAPI nie ma poświadczeń.",
};

/** Polish text of a stored provider/analysis error code; unknown codes stay generic. */
export function providerErrorMessage(code: string | null): string | null {
  if (!code) return null;
  return PROVIDER_ERRORS[code] ?? CODE_MESSAGES[code] ?? "Błąd techniczny po stronie usługi.";
}
