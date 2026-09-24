import { useEffect, useMemo } from "react";
import {
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
  type InfiniteData,
  type QueryClient,
} from "@tanstack/react-query";
import {
  activateAutomation,
  ApiError,
  checkAutomation,
  createAutomation,
  createLinearHoldLabel,
  getAutomation,
  getLinearOptions,
  listAutomations,
  listJiraBoards,
  listJiraFilters,
  listJiraPriorities,
  pauseAutomation,
  previewAutomation,
  updateAutomation,
} from "@/lib/api";
import { AUTOMATION_KEY, AUTOMATIONS_KEY, INTEGRATIONS_KEY } from "@/lib/queryClient";
import { actionErrorMessage } from "@/features/cases/useCaseActions";
import type {
  ApiPage,
  AutomationFilters,
  AutomationPreview,
  AutomationRule,
  AutomationRuleInput,
  AutomationRulePatch,
  AutomationSourceType,
} from "@/types/contract";

// Automation rules (spec §4.6, §7, §11.2). Every rule list under the
// "automations" root is an infinite query of `ApiPage<AutomationRule>` (the
// Case Center schedule and the automation list share that shape), so a
// mutation result can be written into every loaded page. A single rule lives
// under "automation". No mutation is optimistic: the screen shows what the
// backend returned.

const LIST_PAGE_SIZE = 25;
const ALL_PAGE_SIZE = 100;

// ─── Rule schedule of the Case Center header ───────────────────────────────

export type RuleSchedule =
  | { kind: "none" }
  | { kind: "active"; lastCheckAt: string | null; nextCheckAt: string | null };

function latest(values: (string | null)[], pick: (a: number, b: number) => number): string | null {
  let best: { at: number; iso: string } | null = null;
  for (const iso of values) {
    if (!iso) continue;
    const at = new Date(iso).getTime();
    if (Number.isNaN(at)) continue;
    if (!best || pick(at, best.at) === at) best = { at, iso };
  }
  return best?.iso ?? null;
}

export function ruleSchedule(rules: AutomationRule[]): RuleSchedule {
  const active = rules.filter((rule) => rule.enabled);
  if (active.length === 0) return { kind: "none" };
  return {
    kind: "active",
    lastCheckAt: latest(active.map((rule) => rule.last_success_at), Math.max),
    nextCheckAt: latest(active.map((rule) => rule.next_poll_at), Math.min),
  };
}

/**
 * Rules of one project (UUID) or of every project. All pages are read, since
 * "no active rule" must hold for every rule, not only the first page.
 */
export function useRuleSchedule(projectId: string | undefined, enabled: boolean) {
  const filters = useMemo<AutomationFilters>(
    () => (projectId ? { project: projectId, page_size: ALL_PAGE_SIZE } : { page_size: ALL_PAGE_SIZE }),
    [projectId],
  );

  const query = useInfiniteQuery({
    queryKey: AUTOMATIONS_KEY(filters),
    queryFn: ({ pageParam }) => listAutomations({ ...filters, cursor: pageParam }),
    getNextPageParam: (last) => last.meta.next_cursor ?? undefined,
    initialPageParam: undefined as string | undefined,
    enabled,
  });

  const { hasNextPage, isFetchingNextPage, isError, fetchNextPage } = query;
  useEffect(() => {
    if (hasNextPage && !isFetchingNextPage && !isError) void fetchNextPage();
  }, [hasNextPage, isFetchingNextPage, isError, fetchNextPage]);

  const schedule = useMemo(
    () => (query.data && !hasNextPage ? ruleSchedule(query.data.pages.flatMap((page) => page.items)) : null),
    [query.data, hasNextPage],
  );

  return { schedule, isError: isError && !schedule, isLoading: !schedule && !isError };
}

// ─── Rule reads ────────────────────────────────────────────────────────────

/** The automation list: pages of 25 loaded on demand. */
export function useAutomationList() {
  const filters: AutomationFilters = { page_size: LIST_PAGE_SIZE };
  return useInfiniteQuery({
    queryKey: AUTOMATIONS_KEY(filters),
    queryFn: ({ pageParam }) => listAutomations({ ...filters, cursor: pageParam }),
    getNextPageParam: (last) => last.meta.next_cursor ?? undefined,
    initialPageParam: undefined as string | undefined,
  });
}

export function useAutomation(id: string | undefined) {
  return useQuery({
    queryKey: AUTOMATION_KEY(id ?? ""),
    queryFn: () => getAutomation(id as string),
    enabled: Boolean(id),
  });
}

/** Boards or saved filters of a Jira connection; the cursor is pinned to `q`. */
export function useJiraSources(connectionId: string, sourceType: AutomationSourceType, q: string) {
  return useInfiniteQuery({
    queryKey: [...INTEGRATIONS_KEY, connectionId, "jira", sourceType, { q }],
    queryFn: ({ pageParam }) =>
      (sourceType === "board" ? listJiraBoards : listJiraFilters)(connectionId, { q: q || undefined, cursor: pageParam }),
    getNextPageParam: (last) => last.meta.next_cursor ?? undefined,
    initialPageParam: undefined as string | undefined,
    enabled: Boolean(connectionId),
  });
}

/** Jira priorities in the order of the Jira response; never sorted by ID. */
export function useJiraPriorities(connectionId: string) {
  return useQuery({
    queryKey: [...INTEGRATIONS_KEY, connectionId, "jira", "priorities"],
    queryFn: () => listJiraPriorities(connectionId).then((page) => page.items),
    enabled: Boolean(connectionId),
  });
}

export const LINEAR_OPTIONS_KEY = (projectId: string) => ["linear-options", projectId] as const;

export function useLinearOptions(projectId: string) {
  return useQuery({
    queryKey: LINEAR_OPTIONS_KEY(projectId),
    queryFn: () => getLinearOptions(projectId),
    enabled: Boolean(projectId),
  });
}

// ─── Rule mutations ────────────────────────────────────────────────────────

/** Writes a rule returned by the backend into the detail and every loaded list page. */
function applyRule(queryClient: QueryClient, rule: AutomationRule) {
  queryClient.setQueryData(AUTOMATION_KEY(rule.id), rule);
  queryClient.setQueriesData<InfiniteData<ApiPage<AutomationRule>>>({ queryKey: ["automations"] }, (data) =>
    data?.pages
      ? {
          ...data,
          pages: data.pages.map((page) => ({
            ...page,
            items: page.items.map((item) => (item.id === rule.id ? rule : item)),
          })),
        }
      : data,
  );
}

function useRuleResult() {
  const queryClient = useQueryClient();
  return (rule: AutomationRule) => {
    applyRule(queryClient, rule);
    void queryClient.invalidateQueries({ queryKey: ["automations"] });
  };
}

/** Pause and activation: the returned rule is shown, and every list is refetched even after a refusal. */
function useRuleAction() {
  const queryClient = useQueryClient();
  return {
    apply: (rule: AutomationRule) => applyRule(queryClient, rule),
    refetch: () => queryClient.invalidateQueries({ queryKey: ["automations"] }),
  };
}

/** Saving never activates: POST creates a disabled rule. */
export function useCreateAutomation() {
  const onRule = useRuleResult();
  return useMutation({
    mutationFn: (input: AutomationRuleInput) => createAutomation(input),
    onSuccess: onRule,
  });
}

/** Partial PATCH with the `version` the form was loaded with; a 409 is surfaced, never retried. */
export function useUpdateAutomation(id: string) {
  const onRule = useRuleResult();
  return useMutation({
    mutationFn: (patch: AutomationRulePatch) => updateAutomation(id, patch),
    onSuccess: onRule,
  });
}

/** Dry run on the saved version: no message, ticket, analysis or comment. */
export function usePreviewAutomation(id: string) {
  return useMutation({ mutationFn: () => previewAutomation(id) });
}

export function useActivateAutomation(id: string) {
  const action = useRuleAction();
  return useMutation({
    mutationFn: (version: number) => activateAutomation(id, { version, confirmed: true }),
    onSuccess: (result) => action.apply(result.rule),
    onSettled: action.refetch,
  });
}

export function usePauseAutomation(id: string) {
  const action = useRuleAction();
  return useMutation({
    mutationFn: (version: number) => pauseAutomation(id, { version }),
    onSuccess: action.apply,
    onSettled: action.refetch,
  });
}

export function useCheckAutomation(id: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () => checkAutomation(id),
    onSettled: () => queryClient.invalidateQueries({ queryKey: ["automations"] }),
  });
}

/** Reuses or creates the hold label in Linear; a write, so it needs a confirmation. */
export function useCreateHoldLabel(projectId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (teamId: string) => createLinearHoldLabel(projectId, { team_id: teamId, confirmed: true }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: LINEAR_OPTIONS_KEY(projectId) }),
  });
}

// ─── Vocabulary ────────────────────────────────────────────────────────────

// Error envelope codes of the automation endpoints (IntakePresenter) and the
// ActivationCheck failure codes carried in `error.fields`.
const CODE_MESSAGES: Record<string, string> = {
  stale_version:
    "Reguła zmieniła się w międzyczasie. Wczytaj aktualną wersję i sprawdź ją przed ponowieniem akcji.",
  effects_disabled: "Efekty zewnętrzne są wyłączone w konfiguracji Harmony. Reguły nie można teraz aktywować.",
  intake_disabled: "Obsługa zgłoszeń Jira jest wyłączona w konfiguracji Harmony.",
  source_conflict: "To samo źródło obserwuje już inna aktywna reguła. Wstrzymaj tamtą regułę albo wybierz inne źródło.",
  scan_in_progress: "Sprawdzenie już trwa.",
  scan_capacity: "Wykorzystano limit równoległych sprawdzeń. Spróbuj za chwilę.",
  rule_not_active: "Reguła nie jest aktywna.",
  scheduler_unavailable: "Harmonogram sprawdzeń jest niedostępny. Spróbuj ponownie później.",
  scan_limit_exceeded: "Źródło zwraca zbyt wiele zgłoszeń (ponad 10 000). Zawęź filtr w Jira.",
  immutable_after_activation:
    "Po pierwszej aktywacji nie można zmienić projektu, połączenia Jira, celu w Linear ani polityki istniejących zgłoszeń.",
  validation_failed: "Serwer odrzucił część pól. Popraw zaznaczone wartości.",
  confirmation_required: "Akcja wymaga potwierdzenia.",
  not_found: "Nie znaleziono reguły. Mogła zostać usunięta — wróć do listy.",
  jira_auth_failed: "Jira odrzuciła poświadczenia połączenia.",
  jira_source_not_found: "Jira nie znalazła wybranej tablicy lub filtra albo połączenie nie ma do nich dostępu.",
  jira_rate_limited: "Jira ograniczyła liczbę zapytań. Spróbuj ponownie za chwilę.",
  jira_unavailable: "Jira jest teraz niedostępna. Spróbuj ponownie później.",
  jira_invalid_configuration: "Konfiguracja połączenia Jira jest niepoprawna.",
  jira_connection_unavailable: "Połączenie Jira jest wyłączone albo nie ma poświadczeń.",
  jira_connection_disabled: "Połączenie Jira jest wyłączone.",
  credentials_missing: "Połączenie nie ma zapisanych poświadczeń.",
  jira_priority_unknown: "Co najmniej jeden priorytet nie istnieje już w Jira.",
  linear_auth_failed: "Linear odrzucił token projektu.",
  linear_unavailable: "Linear jest teraz niedostępny. Spróbuj ponownie później.",
  linear_label_create_failed: "Nie udało się utworzyć etykiety w Linear.",
  missing_linear_api_token: "Projekt nie ma tokenu Linear.",
  linear_team_missing: "Zespół Linear nie jest dostępny dla tego projektu.",
  linear_project_missing: "Projekt Linear nie należy do wybranego zespołu albo nie jest dostępny.",
  linear_todo_state_missing: "W zespole Linear nie ma stanu o nazwie Todo.",
  linear_todo_state_mismatch:
    "Zapisany stan Todo nie odpowiada bieżącemu stanowi Todo w zespole Linear. Wybierz zespół ponownie i zapisz regułę.",
  linear_hold_label_missing: "W zespole Linear brakuje etykiety ochronnej harmony:analysis-only.",
  linear_hold_label_mismatch:
    "Zapisana etykieta ochronna nie odpowiada etykiecie w zespole Linear. Wybierz zespół ponownie i zapisz regułę.",
  project_missing: "Projekt reguły nie istnieje.",
  analysis_profile_unavailable: "Profil analizy nie jest skonfigurowany.",
  email_connection_unavailable: "Połączenie SMTP jest wyłączone albo nie ma poświadczeń.",
  sms_connection_unavailable: "Połączenie SMSAPI jest wyłączone albo nie ma poświadczeń.",
  email_recipients_missing: "Kanał e-mail jest włączony, ale nie ma adresatów.",
  sms_recipients_missing: "Kanał SMS jest włączony, ale nie ma adresatów.",
  intake_public_url_invalid:
    "Harmony nie ma poprawnego adresu publicznego (intake.public_url), więc linki w powiadomieniach by nie działały.",
};

const GENERIC_REQUIREMENT = "Warunek aktywacji nie jest spełniony. Sprawdź konfigurację reguły i połączeń.";

/** Polish text of an activation failure code; an unknown code gets a generic text. */
export function requirementMessage(code: string): string {
  return CODE_MESSAGES[code] ?? GENERIC_REQUIREMENT;
}

/** Polish text of a failed automation request. */
export function automationErrorMessage(error: unknown): string {
  if (error instanceof ApiError && CODE_MESSAGES[error.code]) return CODE_MESSAGES[error.code];
  return actionErrorMessage(error);
}

/** Activation failure codes per field (`error.fields` of a 422 activation refusal). */
export function activationFailures(error: unknown): Record<string, string[]> | null {
  if (!(error instanceof ApiError) || error.status !== 422 || !error.fields) return null;
  const codes = Object.values(error.fields).flat();
  const isActivation = codes.length > 0 && codes.every((code) => /^[a-z0-9_]+$/.test(code));
  return isActivation && error.code !== "validation_failed" ? error.fields : null;
}

const RULE_ERRORS: Record<string, string> = {
  scan_limit_exceeded: "Źródło zwraca zbyt wiele zgłoszeń — zawęź filtr w Jira.",
  jira_auth_failed: "Jira odrzuciła poświadczenia połączenia.",
  jira_source_not_found: "Jira nie znalazła źródła reguły.",
  jira_rate_limited: "Jira ograniczyła liczbę zapytań.",
  jira_unavailable: "Jira była niedostępna.",
  jira_invalid_configuration: "Konfiguracja połączenia Jira jest niepoprawna.",
};

/** Polish text of a rule `last_error_code`. */
export function ruleErrorMessage(code: string | null): string | null {
  if (!code) return null;
  return RULE_ERRORS[code] ?? CODE_MESSAGES[code] ?? "Ostatnie sprawdzenie zakończyło się błędem.";
}

export type RuleState = "active" | "activating" | "error" | "paused" | "draft";

export function ruleState(rule: AutomationRule): RuleState {
  if (rule.enabled) return "active";
  if (rule.activation_status === "activating") return "activating";
  if (rule.activation_status === "error") return "error";
  return rule.activated_at ? "paused" : "draft";
}

export const RULE_STATE_LABEL: Record<RuleState, string> = {
  active: "Aktywna",
  activating: "Trwa skan bazowy",
  error: "Błąd aktywacji",
  paused: "Wstrzymana",
  draft: "Nieaktywna",
};

const timeFormat = new Intl.DateTimeFormat("pl-PL", { dateStyle: "short", timeStyle: "short" });

export function formatRuleTime(iso: string | null): string {
  if (!iso) return "—";
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? "—" : timeFormat.format(date);
}

const plural = new Intl.PluralRules("pl-PL");

/** "1 zgłoszenie", "2 zgłoszenia", "5 zgłoszeń". */
export function issuesCount(count: number): string {
  const form = plural.select(count);
  const word = form === "one" ? "zgłoszenie" : form === "few" ? "zgłoszenia" : "zgłoszeń";
  return `${count.toLocaleString("pl-PL")} ${word}`;
}

/** Import count of an `include_existing` activation: every current match without a case. */
export function importCount(preview: AutomationPreview): number {
  return preview.warnings.find((entry) => entry.code === "include_existing_import")?.count ?? preview.match_count;
}
