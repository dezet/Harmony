import { useEffect, useMemo } from "react";
import { useInfiniteQuery, useMutation, useQueryClient, type InfiniteData, type QueryClient } from "@tanstack/react-query";
import {
  ApiError,
  createIntegration,
  getIntegration,
  listAutomations,
  listIntegrations,
  testIntegration,
  testSendIntegration,
  updateIntegration,
} from "@/lib/api";
import { AUTOMATIONS_KEY, INTEGRATIONS_KEY } from "@/lib/queryClient";
import { actionErrorMessage } from "@/features/cases/useCaseActions";
import type {
  ApiPage,
  AutomationFilters,
  AutomationRule,
  IntegrationConnection,
  IntegrationConnectionInput,
  IntegrationConnectionPatch,
  IntegrationKind,
} from "@/types/contract";

// Integration connections (spec §4.6, §10–12). Every screen reads the same
// all-pages list under CONNECTIONS_KEY, so the automation form and this page
// share one cache entry. A mutation result is written into that list and the
// list is refetched; nothing is optimistic. Secrets never enter the cache:
// the API returns only `secret_state`.

const ALL_PAGE_SIZE = 100;

export const CONNECTIONS_KEY = [...INTEGRATIONS_KEY, { page_size: ALL_PAGE_SIZE }] as const;

function useAllPages<T>(query: {
  data: InfiniteData<ApiPage<T>> | undefined;
  hasNextPage: boolean;
  isFetchingNextPage: boolean;
  isError: boolean;
  fetchNextPage: () => Promise<unknown>;
}): T[] {
  const { data, hasNextPage, isFetchingNextPage, isError, fetchNextPage } = query;
  useEffect(() => {
    if (hasNextPage && !isFetchingNextPage && !isError) void fetchNextPage();
  }, [hasNextPage, isFetchingNextPage, isError, fetchNextPage]);
  return useMemo(() => data?.pages.flatMap((page) => page.items) ?? [], [data]);
}

/** Every integration connection (all pages). */
export function useConnections() {
  const query = useInfiniteQuery({
    queryKey: CONNECTIONS_KEY,
    queryFn: ({ pageParam }) => listIntegrations({ page_size: ALL_PAGE_SIZE, cursor: pageParam }),
    getNextPageParam: (last) => last.meta.next_cursor ?? undefined,
    initialPageParam: undefined as string | undefined,
  });
  const connections = useAllPages<IntegrationConnection>(query);
  return {
    connections,
    isPending: query.isPending || query.hasNextPage,
    isError: query.isError,
    error: query.error,
    refetch: query.refetch,
  };
}

const ALL_RULES: AutomationFilters = { page_size: ALL_PAGE_SIZE };

/** Every automation rule (all pages; the same entry as the Case Center schedule). */
export function useAllRules() {
  const query = useInfiniteQuery({
    queryKey: AUTOMATIONS_KEY(ALL_RULES),
    queryFn: ({ pageParam }) => listAutomations({ ...ALL_RULES, cursor: pageParam }),
    getNextPageParam: (last) => last.meta.next_cursor ?? undefined,
    initialPageParam: undefined as string | undefined,
  });
  const rules = useAllPages<AutomationRule>(query);
  return { rules, ready: query.isSuccess && !query.hasNextPage };
}

/** Rules that use a connection as their Jira source or notification channel. */
export function rulesUsing(rules: AutomationRule[], connectionId: string): AutomationRule[] {
  return rules.filter(
    (rule) =>
      rule.jira_connection_id === connectionId ||
      rule.email_connection_id === connectionId ||
      rule.sms_connection_id === connectionId,
  );
}

// ─── Mutations ─────────────────────────────────────────────────────────────

function writeConnection(queryClient: QueryClient, connection: IntegrationConnection) {
  queryClient.setQueryData<InfiniteData<ApiPage<IntegrationConnection>>>(CONNECTIONS_KEY, (data) =>
    data?.pages
      ? {
          ...data,
          pages: data.pages.map((page) => ({
            ...page,
            items: page.items.map((item) => (item.id === connection.id ? connection : item)),
          })),
        }
      : data,
  );
}

function useConnectionResult() {
  const queryClient = useQueryClient();
  return {
    apply: (connection: IntegrationConnection) => writeConnection(queryClient, connection),
    refetch: () => queryClient.invalidateQueries({ queryKey: CONNECTIONS_KEY }),
    refetchRules: () => queryClient.invalidateQueries({ queryKey: ["automations"] }),
  };
}

/** New connections are created disabled. */
export function useCreateIntegration() {
  const result = useConnectionResult();
  return useMutation({
    mutationFn: (input: IntegrationConnectionInput) => createIntegration(input),
    onSettled: result.refetch,
  });
}

/** Partial PATCH with the loaded `version`; a 409 is shown, never retried. */
export function useUpdateIntegration(id: string) {
  const result = useConnectionResult();
  return useMutation({
    mutationFn: (patch: IntegrationConnectionPatch) => updateIntegration(id, patch),
    onSuccess: (connection, patch) => {
      result.apply(connection);
      // Clearing the secret or disabling pauses dependent rules on the backend.
      if (patch.clear_secret || patch.enabled === false) void result.refetchRules();
    },
    onSettled: result.refetch,
  });
}

/** Reads the current version of a connection after a conflict. */
export function useReloadIntegration(id: string) {
  const result = useConnectionResult();
  return useMutation({
    mutationFn: () => getIntegration(id),
    onSuccess: result.apply,
  });
}

/** Read-only connection test: no message is ever sent; the version does not change. */
export function useTestIntegration(connection: IntegrationConnection) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () => testIntegration(connection.id),
    onSuccess: (check) => {
      const current =
        queryClient
          .getQueryData<InfiniteData<ApiPage<IntegrationConnection>>>(CONNECTIONS_KEY)
          ?.pages.flatMap((page) => page.items)
          .find((item) => item.id === connection.id) ?? connection;
      writeConnection(queryClient, {
        ...current,
        health: check.health,
        error_code: check.error_code,
        last_checked_at: check.checked_at,
      });
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: CONNECTIONS_KEY }),
  });
}

/** Confirmed test-send; the caller owns the Idempotency-Key of the attempt. */
export function useTestSend(id: string) {
  return useMutation({
    mutationFn: (body: { recipient: string; idempotencyKey: string }) =>
      testSendIntegration(id, { recipient: body.recipient, confirmed: true, idempotencyKey: body.idempotencyKey }),
  });
}

// ─── Vocabulary ────────────────────────────────────────────────────────────

export const KIND_LABEL: Record<IntegrationKind, string> = { jira_cloud: "Jira", smtp: "E-mail", smsapi: "SMS" };

export const SECRET_LABEL: Record<IntegrationKind, string> = {
  jira_cloud: "Token API Jira",
  smtp: "Hasło SMTP",
  smsapi: "Token SMSAPI",
};

// Stored `error_code` of a connection test (ConnectionCheck, JiraAccess,
// Notifications.{Smtp,Smsapi}): what to do next, never a raw provider text.
const CHECK_HINTS: Record<string, string> = {
  jira_credentials_missing: "Brak tokenu API Jira. Zapisz token w formularzu połączenia.",
  jira_auth_failed:
    "Jira odrzuciła token (401/403). Sprawdź, czy token nie wygasł i ma dostęp do witryny; w trybie klasycznym e-mail konta musi należeć do właściciela tokenu.",
  jira_source_not_found: "Jira zwróciła 404. Sprawdź adres witryny albo Cloud ID.",
  jira_rate_limited: "Jira ograniczyła liczbę zapytań. Ponów test za kilka minut.",
  jira_invalid_configuration:
    "Ustawienia są niekompletne: tryb klasyczny wymaga adresu witryny i e-maila konta, tryb z zakresami — Cloud ID. Uzupełnij je i ponów test.",
  jira_unavailable: "Nie udało się połączyć z Jira. Sprawdź dostęp do sieci z serwera Harmony i ponów test.",
  smtp_host_not_allowed:
    "Tego hosta nie ma na liście dozwolonych hostów SMTP wdrożenia (intake.smtp_allowed_hosts). Poproś operatora wdrożenia o dopisanie hosta albo wybierz host z listy.",
  smtp_auth_failed: "Serwer SMTP odrzucił użytkownika lub hasło.",
  smtp_auth_unavailable: "Serwer SMTP nie oferuje uwierzytelniania po zestawieniu TLS. Sprawdź tryb szyfrowania i port.",
  smtp_tls_failed:
    "Nie udało się zestawić TLS. Sprawdź tryb szyfrowania (STARTTLS zwykle na porcie 587, TLS na 465) i certyfikat serwera.",
  smtp_tls_required: "Serwer nie zaoferował STARTTLS. Wybierz tryb TLS (zwykle port 465) albo inny serwer.",
  smtp_tls_unavailable: "Serwer nie zaoferował STARTTLS. Wybierz tryb TLS (zwykle port 465) albo inny serwer.",
  smtp_ca_store_unavailable: "Serwer Harmony nie ma magazynu certyfikatów CA. Zgłoś to operatorowi wdrożenia.",
  smtp_credentials_missing: "Brak użytkownika albo hasła SMTP. Uzupełnij je w formularzu połączenia.",
  smtp_invalid_settings: "Ustawienia SMTP są niepoprawne. Sprawdź port i tryb szyfrowania.",
  smtp_timeout:
    "Serwer SMTP nie odpowiedział w limicie czasu, więc stan jest nieznany. Sprawdź host, port i zaporę, potem ponów test.",
  smtp_unavailable: "Nie udało się połączyć z serwerem SMTP. Sprawdź host i port, potem ponów test.",
  smtp_temporary_failure: "Serwer SMTP zgłosił błąd tymczasowy. Ponów test za chwilę.",
  smtp_rejected: "Serwer SMTP odrzucił sesję. Sprawdź ustawienia konta pocztowego.",
  sms_credentials_missing: "Brak tokenu SMSAPI. Zapisz token w formularzu połączenia.",
  sms_invalid_settings: "Brak poprawnej nazwy nadawcy SMS. Uzupełnij ją w formularzu połączenia.",
  sms_auth_failed: "SMSAPI odrzuciło token. Sprawdź, czy token jest aktywny i ma uprawnienia do konta.",
  sms_unavailable: "Nie udało się odczytać konta SMSAPI. Ponów test za chwilę.",
  connection_check_failed: "Test przerwał nieoczekiwany błąd po stronie Harmony. Ponów test; jeśli się powtarza, sprawdź dziennik serwera.",
  unsupported_connection_kind: "Ten rodzaj połączenia nie ma testu.",
};

/** A concrete next step for a failed connection test; an unknown code is named, never hidden. */
export function checkHint(code: string | null): string {
  if (code && CHECK_HINTS[code]) return CHECK_HINTS[code];
  return `Test nie powiódł się${code ? ` (kod: ${code})` : ""}. Sprawdź ustawienia i sekret, potem ponów test.`;
}

export type StatusTone = "success" | "warning" | "danger" | "neutral";

export interface ConnectionStatus {
  tone: StatusTone;
  label: string;
  hint: string | null;
}

/**
 * „Połączono” only for a checked, enabled connection with a stored secret.
 * An unchecked or failed connection is never green.
 */
export function connectionStatus(connection: IntegrationConnection): ConnectionStatus {
  if (connection.secret_state === "unset") {
    return { tone: "warning", label: "Brak sekretu", hint: `Zapisz ${SECRET_LABEL[connection.kind].toLowerCase()}, aby połączenie mogło działać.` };
  }
  if (connection.health === "error") return { tone: "danger", label: "Błąd połączenia", hint: checkHint(connection.error_code) };
  if (connection.health !== "ok") {
    return {
      tone: "warning",
      label: "Nie sprawdzono",
      hint: "Stan nieznany — użyj „Sprawdź połączenie”. Test nie wysyła żadnej wiadomości.",
    };
  }
  if (!connection.enabled) return { tone: "neutral", label: "Wyłączone", hint: "Ostatni test był poprawny, ale połączenie jest wyłączone." };
  return { tone: "success", label: "Połączono", hint: null };
}

/** What stops while a connection is disabled (Dispatcher, Scheduler). */
export function stoppedEffects(kind: IntegrationKind): string {
  if (kind === "jira_cloud") {
    return "Efekty zatrzymane: reguły korzystające z tego połączenia nie sprawdzają Jira, nie powstają nowe sprawy ani komentarze.";
  }
  const channel = kind === "smtp" ? "e-maile" : "SMS-y";
  return `Efekty zatrzymane: Harmony nie wysyła tym połączeniem — alerty (${channel}) czekają w kolejce do ponownego włączenia, a wiadomość testowa jest niedostępna.`;
}

// Error envelope codes of the integration endpoints (IntegrationController).
const CODE_MESSAGES: Record<string, string> = {
  stale_version:
    "Połączenie zmieniło się w międzyczasie. Wczytaj aktualną wersję i sprawdź ją przed ponownym zapisem.",
  validation_failed: "Serwer odrzucił część pól. Popraw zaznaczone wartości.",
  not_found: "Nie znaleziono połączenia. Mogło zostać usunięte — odśwież stronę.",
  connection_disabled: "Połączenie jest wyłączone. Włącz je, aby wysłać wiadomość testową.",
  intake_disabled:
    "Obsługa zgłoszeń jest wyłączona w konfiguracji Harmony (intake.enabled), więc wiadomość testowa nie zostanie wysłana.",
  effects_disabled:
    "Efekty zewnętrzne są wyłączone w konfiguracji Harmony (intake.effects_enabled), więc wiadomość testowa nie zostanie wysłana.",
  idempotency_key_conflict: "Ta próba została już użyta dla innego odbiorcy. Rozpocznij nową próbę.",
  invalid_idempotency_key: "Brak poprawnego identyfikatora próby. Zamknij okno i otwórz je ponownie.",
  test_send_unsupported: "Wiadomość testowa jest dostępna tylko dla połączeń SMTP i SMSAPI.",
  confirmation_required: "Potwierdź koszt wysyłki.",
  missing_linear_api_token: "Projekt nie ma tokenu Linear, a Harmony nie ma tokenu globalnego. Zapisz token w ustawieniach projektu.",
  linear_auth_failed: "Linear odrzucił token projektu. Zapisz aktualny token w ustawieniach projektu.",
  linear_unavailable: "Linear jest teraz niedostępny. Spróbuj ponownie później.",
};

/** Polish text of a failed integration request. */
export function integrationErrorMessage(error: unknown): string {
  if (error instanceof ApiError && CODE_MESSAGES[error.code]) return CODE_MESSAGES[error.code];
  return actionErrorMessage(error);
}
