import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { useForm, useWatch, type Resolver } from "react-hook-form";
import { yupResolver } from "@hookform/resolvers/yup";
import { Check, Clock, FlaskConical, Loader2, Pause, ShieldCheck, SlidersHorizontal, TriangleAlert } from "lucide-react";
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
import { ApiError } from "@/lib/api";
import { cn } from "@/lib/utils";
import { useProjects } from "@/features/projects/useProjects";
import { ActivationDialog, PreviewResult, RuleSummary } from "@/features/automations/AutomationPreview";
import {
  automationFormSchema,
  emptyFormValues,
  formatInterval,
  formValuesFromRule,
  INTERVAL_PRESET_MINUTES,
  parseIntervalSeconds,
  rulePatch,
  toRuleInput,
  UNIT_LABEL,
  type AutomationFormValues,
  type IntervalUnit,
} from "@/features/automations/automationSchema";
import {
  activationFailures,
  automationErrorMessage,
  formatRuleTime,
  requirementMessage,
  ruleErrorMessage,
  ruleState,
  RULE_STATE_LABEL,
  useActivateAutomation,
  useAutomation,
  useCheckAutomation,
  useCreateAutomation,
  useCreateHoldLabel,
  useJiraPriorities,
  useJiraSources,
  useLinearOptions,
  usePauseAutomation,
  usePreviewAutomation,
  useUpdateAutomation,
} from "@/features/automations/useAutomations";
import { useConnections } from "@/features/integrations/useIntegrations";
import type { AutomationRule, AutomationSourceType, IntegrationConnection, IntegrationKind } from "@/types/contract";

// Rule editor of layout A (spec §4.6, §7.1): three configuration sections and
// the „Podgląd działania” panel. Saving never activates; the dry run and the
// activation work on the saved version only. The form keeps the rule it was
// loaded from (`base`): its `config_version` is the PATCH `version`, so an
// edit made elsewhere is a 409 and never gets overwritten. A newer version is
// adopted automatically only while the form has no unsaved changes.

type FieldName = keyof AutomationFormValues;
type Notice = { tone: "success" | "warning"; text: string };
type ActionFailure = { title: string; messages: string[] };

const input =
  "w-full min-w-0 rounded-[6px] border bg-background px-[11px] py-2.5 text-xs text-foreground outline-none focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/50 disabled:cursor-not-allowed disabled:opacity-60 aria-invalid:border-destructive";
const field = "flex min-w-0 flex-col gap-2 text-[11px]";
const hint = "text-[10px] leading-[1.65] text-muted-foreground";
const checkRow = "flex items-center gap-2 text-[11px] leading-[1.6]";
const checkbox = "size-[15px] accent-primary disabled:cursor-not-allowed";
const smallButton = "h-auto min-h-[30px] self-start rounded-[7px] px-[9px] py-1.5 text-[11px] font-[550]";
const panelButton =
  "h-auto min-h-[35px] w-full gap-[7px] rounded-[7px] px-3 py-[9px] text-[11px] font-[550] [&_svg:not([class*='size-'])]:size-3.5";
const actionButton =
  "h-auto min-h-[35px] gap-[7px] rounded-[7px] px-3 py-[9px] text-[11px] font-[550] leading-[1.3] max-[600px]:flex-1 [&_svg:not([class*='size-'])]:size-3.5";

const CREATED_NOTICE: Notice = {
  tone: "success",
  text: "Reguła zapisana i pozostaje nieaktywna. Sprawdź podgląd, a potem aktywuj ją osobnym krokiem.",
};

const SAVE_FIELD_MESSAGES: Partial<Record<FieldName, string>> = {
  name: "Serwer odrzucił nazwę — użyj od 1 do 100 znaków.",
  interval_value: "Serwer odrzucił interwał — dozwolone jest 60–86 400 s.",
  source_id: "Serwer odrzucił identyfikator źródła.",
  priority_ids: "Serwer odrzucił listę priorytetów.",
  email_recipients: "Serwer odrzucił listę adresów e-mail — sprawdź adresy i ich liczbę.",
  sms_recipients: "Numery muszą mieć format międzynarodowy z prefiksem kraju, np. +48 600 100 200.",
};

const FORM_FIELDS = new Set<string>(Object.keys(emptyFormValues()));

function formField(key: string): FieldName | null {
  if (key === "interval_seconds") return "interval_value";
  return FORM_FIELDS.has(key) ? (key as FieldName) : null;
}

function ids(...values: (string | false | null | undefined)[]): string | undefined {
  const joined = values.filter(Boolean).join(" ");
  return joined || undefined;
}

function sameSet(a: string[], b: string[]): boolean {
  return a.length === b.length && [...a].sort().join("\n") === [...b].sort().join("\n");
}

function isOn(rule: AutomationRule | undefined): boolean {
  return Boolean(rule && (rule.enabled || rule.activation_status === "activating"));
}

function connectionLabel(connection: IntegrationConnection): string {
  return connection.enabled ? connection.name : `${connection.name} (wyłączone)`;
}

function FieldMessage({ id, message }: { id: string; message: string | undefined }) {
  if (!message) return null;
  return (
    <span id={id} className="text-[10px] leading-[1.6] text-destructive">
      {message}
    </span>
  );
}

function LoadError({ text, detail, retryLabel, onRetry }: { text: string; detail: string; retryLabel: string; onRetry: () => void }) {
  return (
    <div role="alert" className="grid justify-items-start gap-1 text-[10px] leading-[1.6] text-destructive">
      <span className="font-[550]">{text}</span>
      <span>{detail}</span>
      <Button type="button" variant="outline" size="sm" className={cn(smallButton, "bg-card")} onClick={onRetry}>
        {retryLabel}
      </Button>
    </div>
  );
}

function Section({ step, title, subtitle, aside, children }: { step: number; title: string; subtitle: string; aside?: ReactNode; children: ReactNode }) {
  const titleId = useId();
  return (
    <section aria-labelledby={titleId} className="border-b px-[25px] py-[22px] last:border-b-0 max-[600px]:px-[17px] max-[600px]:py-5">
      <div className="mb-[19px] flex items-center gap-[11px]">
        <span aria-hidden className="flex size-6 shrink-0 items-center justify-center rounded-[7px] bg-accent text-[11px] text-primary">
          {step}
        </span>
        <div>
          <h2 id={titleId} className="text-[14px] font-semibold">
            {title}
          </h2>
          <small className="mt-[5px] block text-[10px] text-muted-foreground">{subtitle}</small>
        </div>
        {aside}
      </div>
      {children}
    </section>
  );
}

function Note({ icon, children }: { icon: "check" | "shield"; children: ReactNode }) {
  const Icon = icon === "check" ? Check : ShieldCheck;
  return (
    <div className="mt-[15px] flex items-start gap-[9px] rounded-[7px] border bg-background p-3 text-[11px] leading-[1.7] text-muted-foreground">
      <Icon aria-hidden className="mt-0.5 size-[15px] shrink-0 text-primary" strokeWidth={1.6} />
      <div>{children}</div>
    </div>
  );
}

interface SelectOption {
  value: string;
  label: string;
}

interface SelectFieldProps {
  id: string;
  label: string;
  value: string;
  options: SelectOption[];
  placeholder: string;
  onChange: (value: string) => void;
  disabled?: boolean;
  loading?: boolean;
  error?: string;
  hint?: ReactNode;
  children?: ReactNode;
}

/** Native select of layout A; a stored ID missing from the options stays visible and selected. */
function SelectField({ id, label, value, options, placeholder, onChange, disabled, loading, error, hint: hintText, children }: SelectFieldProps) {
  const known = options.some((option) => option.value === value);
  return (
    <div className={field}>
      <label htmlFor={id}>{label}</label>
      <select
        id={id}
        className={input}
        value={value}
        disabled={disabled}
        aria-invalid={error ? true : undefined}
        aria-describedby={ids(hintText ? `${id}-hint` : null, error ? `${id}-error` : null)}
        onChange={(event) => onChange(event.target.value)}
      >
        <option value="">{loading ? "Wczytywanie…" : placeholder}</option>
        {value && !known ? <option value={value}>{loading ? `ID ${value}` : `ID ${value} (niedostępne na liście)`}</option> : null}
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
      {hintText ? (
        <small id={`${id}-hint`} className={hint}>
          {hintText}
        </small>
      ) : null}
      {children}
      <FieldMessage id={`${id}-error`} message={error} />
    </div>
  );
}

const SOURCE_TEXT: Record<AutomationSourceType, { label: string; search: string; more: string; error: string; retry: string; placeholder: string }> = {
  board: {
    label: "Tablica Jira",
    search: "Szukaj tablicy",
    more: "Wczytaj więcej tablic",
    error: "Nie udało się pobrać tablic z Jira.",
    retry: "Ponów pobieranie tablic",
    placeholder: "Wybierz tablicę",
  },
  filter: {
    label: "Filtr Jira",
    search: "Szukaj filtra",
    more: "Wczytaj więcej filtrów",
    error: "Nie udało się pobrać filtrów z Jira.",
    retry: "Ponów pobieranie filtrów",
    placeholder: "Wybierz zapisany filtr",
  },
};

interface SourcePickerProps {
  id: string;
  connectionId: string;
  sourceType: AutomationSourceType;
  value: string;
  error?: string;
  onChange: (value: string, name: string | undefined) => void;
}

/** Board or saved filter by explicit Jira ID; search restarts paging from the first page. */
function SourcePicker({ id, connectionId, sourceType, value, error, onChange }: SourcePickerProps) {
  const text = SOURCE_TEXT[sourceType];
  const [search, setSearch] = useState("");
  const [q, setQ] = useState("");
  useEffect(() => {
    const timer = window.setTimeout(() => setQ(search.trim().slice(0, 200)), 300);
    return () => window.clearTimeout(timer);
  }, [search]);

  const sources = useJiraSources(connectionId, sourceType, q);
  const seen = new Set<string>();
  const items = (sources.data?.pages.flatMap((page) => page.items) ?? []).filter((item) =>
    seen.has(item.id) ? false : (seen.add(item.id), true),
  );
  const options = items.map((item) => ({ value: item.id, label: `${item.name} (ID ${item.id})` }));

  return (
    <SelectField
      id={id}
      label={text.label}
      value={value}
      options={options}
      placeholder={text.placeholder}
      onChange={(next) => onChange(next, items.find((item) => item.id === next)?.name)}
      disabled={!connectionId}
      loading={sources.isPending && Boolean(connectionId)}
      error={error}
      hint={connectionId ? "Źródłem jest zapisany filtr tablicy albo zapisany filtr Jira, nie bieżący widok." : "Najpierw wybierz połączenie Jira."}
    >
      {connectionId ? (
        <input
          type="search"
          aria-label={text.search}
          placeholder={text.search}
          className={input}
          value={search}
          maxLength={200}
          onChange={(event) => setSearch(event.target.value)}
        />
      ) : null}
      {sources.isError ? (
        <LoadError text={text.error} detail={automationErrorMessage(sources.error)} retryLabel={text.retry} onRetry={() => void sources.refetch()} />
      ) : null}
      {sources.isSuccess && options.length === 0 ? <small className={hint}>Brak wyników{q ? ` dla „${q}”` : ""}.</small> : null}
      {sources.hasNextPage ? (
        <Button
          type="button"
          variant="outline"
          size="sm"
          className={cn(smallButton, "bg-card")}
          disabled={sources.isFetchingNextPage}
          onClick={() => void sources.fetchNextPage()}
        >
          {sources.isFetchingNextPage ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : null}
          {text.more}
        </Button>
      ) : null}
      {sources.isFetchNextPageError ? <small className="text-[10px] text-destructive">Nie udało się wczytać kolejnej strony.</small> : null}
    </SelectField>
  );
}

interface RuleSwitchProps {
  rule: AutomationRule;
  busy: boolean;
  blockedReasonId: string | undefined;
  onToggle: () => void;
}

function RuleSwitch({ rule, busy, blockedReasonId, onToggle }: RuleSwitchProps) {
  const on = isOn(rule);
  return (
    <div className="ml-auto flex shrink-0 items-center gap-2 text-[11px]">
      <button
        type="button"
        role="switch"
        aria-checked={on}
        aria-label="Reguła aktywna"
        aria-describedby={on ? undefined : blockedReasonId}
        disabled={busy || (!on && Boolean(blockedReasonId))}
        onClick={onToggle}
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
      <span>{RULE_STATE_LABEL[ruleState(rule)]}</span>
    </div>
  );
}

interface ConfirmProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  cancelLabel: string;
  confirmLabel: string;
  pending?: boolean;
  onConfirm: () => void;
  children: ReactNode;
}

function Confirm({ open, onOpenChange, title, cancelLabel, confirmLabel, pending = false, onConfirm, children }: ConfirmProps) {
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
          <AlertDialogCancel>{cancelLabel}</AlertDialogCancel>
          <Button type="button" disabled={pending} onClick={onConfirm}>
            {pending ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : null}
            {confirmLabel}
          </Button>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

function FailureAlert({ failure }: { failure: ActionFailure | null }) {
  if (!failure) return null;
  return (
    <div
      role="alert"
      aria-label={failure.title}
      className="mt-3 grid gap-1 rounded-[7px] border border-destructive/30 bg-destructive-surface p-3 text-[11px] leading-[1.6] text-destructive"
    >
      <p className="flex items-center gap-1.5 font-[550]">
        <TriangleAlert aria-hidden className="size-3.5 shrink-0" strokeWidth={1.8} />
        {failure.title}
      </p>
      <ul className="grid gap-0.5 pl-5">
        {failure.messages.map((message) => (
          <li key={message} className="list-disc">
            {message}
          </li>
        ))}
      </ul>
    </div>
  );
}

function failureMessages(error: unknown): { messages: string[]; fields: Partial<Record<FieldName, string>> } {
  const blocked = activationFailures(error);
  if (!blocked) return { messages: [automationErrorMessage(error)], fields: {} };
  const fields: Partial<Record<FieldName, string>> = {};
  for (const [key, codes] of Object.entries(blocked)) {
    const name = formField(key);
    if (name) fields[name] = codes.map(requirementMessage).join(" ");
  }
  return { messages: [...new Set(Object.values(blocked).flat().map(requirementMessage))], fields };
}

function connectionsOf(connections: IntegrationConnection[], kind: IntegrationKind): SelectOption[] {
  return connections.filter((entry) => entry.kind === kind).map((entry) => ({ value: entry.id, label: connectionLabel(entry) }));
}

interface AutomationFormProps {
  /** The saved rule; absent for a new rule. */
  rule?: AutomationRule;
}

export function AutomationForm({ rule: initialRule }: AutomationFormProps) {
  const uid = useId();
  const navigate = useNavigate();
  const location = useLocation();
  const ruleQuery = useAutomation(initialRule?.id);
  const latest = ruleQuery.data ?? initialRule;
  const [base, setBase] = useState(initialRule);
  const [conflict, setConflict] = useState(false);
  const [notice, setNotice] = useState<Notice | null>(() =>
    (location.state as { created?: boolean } | null)?.created ? CREATED_NOTICE : null,
  );
  const [saveFailure, setSaveFailure] = useState<ActionFailure | null>(null);
  const [actionFailure, setActionFailure] = useState<ActionFailure | null>(null);
  const [serverErrors, setServerErrors] = useState<Partial<Record<FieldName, string>>>({});
  const [confirmActivation, setConfirmActivation] = useState(false);
  const [confirmLeave, setConfirmLeave] = useState(false);
  const [confirmLabel, setConfirmLabel] = useState(false);
  const [pickedSource, setPickedSource] = useState<{ id: string; name: string } | null>(null);

  const {
    register,
    handleSubmit,
    reset,
    setValue,
    control,
    formState: { errors, isDirty, isSubmitted },
  } = useForm<AutomationFormValues>({
    resolver: yupResolver(automationFormSchema) as Resolver<AutomationFormValues>,
    defaultValues: initialRule ? formValuesFromRule(initialRule) : emptyFormValues(),
  });
  const values = useWatch({ control }) as AutomationFormValues;

  // A newer saved version is adopted only while nothing is edited; otherwise
  // the operator decides (conflict banner).
  const remoteChanged = Boolean(latest && base && latest.config_version !== base.config_version);
  if (latest && base && remoteChanged && !isDirty && !conflict) setBase(latest);

  const resetVersion = useRef(base?.config_version);
  useEffect(() => {
    if (base && resetVersion.current !== base.config_version) {
      resetVersion.current = base.config_version;
      reset(formValuesFromRule(base));
    }
  }, [base, reset]);

  useEffect(() => {
    if (!isDirty) return;
    const warn = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [isDirty]);

  const ruleId = base?.id ?? "";
  const create = useCreateAutomation();
  const update = useUpdateAutomation(ruleId);
  const preview = usePreviewAutomation(ruleId);
  const activate = useActivateAutomation(ruleId);
  const pause = usePauseAutomation(ruleId);
  const check = useCheckAutomation(ruleId);
  const holdLabel = useCreateHoldLabel(values.project_id);

  const projects = useProjects();
  const { connections, isPending: connectionsPending, isError: connectionsError, refetch: refetchConnections } = useConnections();
  const priorities = useJiraPriorities(values.jira_connection_id);
  const sources = useJiraSources(values.jira_connection_id, values.source_type, "");
  const linear = useLinearOptions(values.project_id);

  const saved = Boolean(base);
  const activated = Boolean(latest?.activated_at);
  const on = isOn(latest);
  const firstBaseline = !latest?.baseline_complete_at;
  const busy = activate.isPending || pause.isPending;
  const saving = create.isPending || update.isPending;

  const set = <K extends FieldName>(name: K, value: AutomationFormValues[K]) => {
    setValue(name, value as never, { shouldDirty: true, shouldValidate: isSubmitted });
  };

  const fieldError = (name: FieldName): string | undefined => {
    const error = errors[name] as { message?: string } | { message?: string }[] | undefined;
    if (Array.isArray(error)) return error.find((entry) => entry?.message)?.message ?? serverErrors[name];
    return error?.message ?? serverErrors[name];
  };

  // ─── Derived texts ───────────────────────────────────────────────────────

  const interval = parseIntervalSeconds(values.interval_value, values.interval_unit);
  const sourceItems = sources.data?.pages.flatMap((page) => page.items) ?? [];
  const sourceName =
    (pickedSource?.id === values.source_id ? pickedSource.name : undefined) ??
    sourceItems.find((item) => item.id === values.source_id)?.name;
  const sourceLabel = values.source_id ? (sourceName ?? `ID ${values.source_id}`) : null;
  const priorityList = priorities.data ?? [];
  const priorityNames = values.priority_ids.map((id) => priorityList.find((entry) => entry.id === id)?.name ?? `ID ${id}`);

  const sourceChanged = Boolean(
    base &&
      (values.source_type !== base.source_type ||
        values.source_id !== base.source_id ||
        !sameSet(values.priority_ids, base.priority_ids)),
  );

  const previewData =
    preview.data && base && preview.data.rule_id === base.id && preview.data.config_version === base.config_version
      ? preview.data
      : null;

  const stale = conflict || remoteChanged;
  const previewBlock = !saved
    ? "Zapisz regułę, aby sprawdzić podgląd."
    : stale
      ? "Reguła zmieniła się na serwerze. Wczytaj aktualną wersję."
      : isDirty
        ? "Zapisz zmiany — podgląd sprawdza zapisaną wersję reguły."
        : null;
  const activationBlock = !saved
    ? "Zapisz regułę, aby ją aktywować."
    : stale
      ? "Reguła zmieniła się na serwerze. Wczytaj aktualną wersję przed aktywacją."
      : isDirty
        ? "Zapisz zmiany przed aktywacją — aktywacja dotyczy zapisanej wersji."
        : firstBaseline && latest?.initial_policy === "include_existing" && !previewData
          ? "Najpierw uruchom podgląd — zobaczysz, ile istniejących zgłoszeń zostanie zaimportowanych."
          : null;
  const previewReasonId = `${uid}-preview-reason`;
  const activationReasonId = `${uid}-activation-reason`;

  // ─── Actions ─────────────────────────────────────────────────────────────

  const onSaveError = (error: unknown) => {
    if (error instanceof ApiError && error.status === 409 && error.code === "stale_version") {
      setConflict(true);
      return;
    }
    if (error instanceof ApiError && error.code === "validation_failed" && error.fields) {
      const fields: Partial<Record<FieldName, string>> = {};
      let unmapped = false;
      for (const key of Object.keys(error.fields)) {
        const name = formField(key);
        if (name) fields[name] = SAVE_FIELD_MESSAGES[name] ?? "Serwer odrzucił tę wartość.";
        else unmapped = true;
      }
      setServerErrors(fields);
      setSaveFailure({
        title: "Nie zapisano reguły",
        messages: [
          unmapped
            ? "Serwer odrzucił część konfiguracji. Sprawdź formularz i spróbuj ponownie."
            : "Serwer odrzucił część pól. Popraw zaznaczone wartości.",
        ],
      });
      return;
    }
    setSaveFailure({ title: "Nie zapisano reguły", messages: [automationErrorMessage(error)] });
  };

  const onSubmit = handleSubmit((formValues) => {
    setNotice(null);
    setSaveFailure(null);
    setServerErrors({});
    const ruleInput = toRuleInput(formValues);

    if (!base) {
      create.mutate(ruleInput, {
        onSuccess: (rule) => navigate(`/automations/${rule.id}`, { replace: true, state: { created: true } }),
        onError: onSaveError,
      });
      return;
    }

    const patch = rulePatch(base, ruleInput);
    if (Object.keys(patch).length === 0) {
      setNotice({ tone: "success", text: "Brak zmian do zapisania." });
      return;
    }
    const wasOn = isOn(latest);
    update.mutate(
      { ...patch, version: base.config_version },
      {
        onSuccess: (rule) => {
          setBase(rule);
          setNotice(
            wasOn && !isOn(rule)
              ? {
                  tone: "warning",
                  text: "Zapisano zmiany. Zmiana źródła lub priorytetów wyłączyła regułę — aktywuj ją ponownie, aby Harmony wykonała nowy skan bazowy.",
                }
              : {
                  tone: "success",
                  text: isOn(rule) ? "Zapisano zmiany. Reguła nadal działa." : "Zapisano zmiany. Reguła pozostaje nieaktywna.",
                },
          );
        },
        onError: onSaveError,
      },
    );
  });

  const reload = async () => {
    const fresh = (await ruleQuery.refetch()).data;
    if (fresh) {
      setConflict(false);
      setSaveFailure(null);
      setBase(fresh);
    }
  };

  const runPreview = () => {
    setActionFailure(null);
    preview.mutate();
  };

  const onActivate = () => {
    if (!base) return;
    setNotice(null);
    setActionFailure(null);
    setServerErrors({});
    activate.mutate(base.config_version, {
      onSuccess: (result) => {
        setNotice(
          result.rule.enabled
            ? {
                tone: "success",
                text: `Reguła jest aktywna. Następne sprawdzenie: ${formatRuleTime(result.rule.next_poll_at)}.`,
              }
            : {
                tone: "success",
                text: "Trwa skan bazowy. Reguła włączy się sama po jego poprawnym zakończeniu; do tego czasu nic nie zostanie wysłane.",
              },
        );
      },
      onError: (error) => {
        const { messages, fields } = failureMessages(error);
        setServerErrors(fields);
        setActionFailure({ title: "Reguły nie aktywowano", messages });
      },
      onSettled: () => setConfirmActivation(false),
    });
  };

  const onPause = () => {
    if (!base) return;
    setNotice(null);
    setActionFailure(null);
    pause.mutate(base.config_version, {
      onSuccess: () =>
        setNotice({
          tone: "success",
          text: "Reguła wstrzymana. Nowe skany się nie rozpoczną; już przyjęte sprawy dokończą swoje kroki.",
        }),
      onError: (error) => setActionFailure({ title: "Reguły nie wstrzymano", messages: [automationErrorMessage(error)] }),
    });
  };

  const requestActivation = () => {
    if (!activationBlock) setConfirmActivation(true);
  };

  const onCheck = () => {
    setNotice(null);
    setActionFailure(null);
    check.mutate(undefined, {
      onSuccess: () => setNotice({ tone: "success", text: "Zakolejkowano sprawdzenie. Nowe sprawy pojawią się po zakończeniu skanu." }),
      onError: (error) => setActionFailure({ title: "Nie zakolejkowano sprawdzenia", messages: [automationErrorMessage(error)] }),
    });
  };

  const leave = () => (isDirty ? setConfirmLeave(true) : navigate("/automations"));

  // ─── Linear targets ──────────────────────────────────────────────────────

  const teams = linear.data?.teams ?? [];
  const team = teams.find((entry) => entry.id === values.linear_team_id);
  const linearProjects = (linear.data?.projects ?? []).filter((entry) => entry.team_ids.includes(values.linear_team_id));
  const holdName = linear.data?.hold_label.name ?? "harmony:analysis-only";

  const onTeam = (teamId: string) => {
    const next = teams.find((entry) => entry.id === teamId);
    set("linear_team_id", teamId);
    set("linear_todo_state_id", next?.todo_state_id ?? "");
    set("linear_hold_label_id", next?.hold_label_id ?? "");
    const keep = (linear.data?.projects ?? []).some(
      (entry) => entry.id === values.linear_project_id && entry.team_ids.includes(teamId),
    );
    if (!keep) set("linear_project_id", "");
  };

  const onCreateLabel = () => {
    holdLabel.mutate(values.linear_team_id, {
      onSuccess: (label) => set("linear_hold_label_id", label.label_id),
      onSettled: () => setConfirmLabel(false),
    });
  };

  const togglePriority = (id: string, checked: boolean) => {
    const order = (value: string) => {
      const index = priorityList.findIndex((entry) => entry.id === value);
      return index === -1 ? Number.MAX_SAFE_INTEGER : index;
    };
    const next = checked ? [...values.priority_ids, id] : values.priority_ids.filter((entry) => entry !== id);
    set(
      "priority_ids",
      [...new Set(next)].sort((a, b) => order(a) - order(b)),
    );
  };

  const title = base ? `Reguła: ${base.name}` : "Nowa reguła";
  useEffect(() => {
    document.title = `${title} — Harmony`;
  }, [title]);

  const nameError = fieldError("name");
  const intervalError = fieldError("interval_value");
  const priorityError = fieldError("priority_ids");
  const todoError = fieldError("linear_todo_state_id");
  const labelError = fieldError("linear_hold_label_id");
  const knownPriorities = priorityList.map((entry) => entry.id);
  const unknownPriorities = priorities.isSuccess ? values.priority_ids.filter((id) => !knownPriorities.includes(id)) : [];
  const f = (name: string) => `${uid}-${name}`;

  return (
    <div>
      <div className="mb-[23px] flex items-center justify-between gap-[18px] max-[850px]:items-start max-[600px]:flex-wrap max-[600px]:gap-2.5">
        <div className="min-w-0">
          <h1 className="text-title max-[1150px]:text-[26px] max-[600px]:text-[27px]">{title}</h1>
          <p className="mt-2 text-xs leading-[1.6] text-muted-foreground">Jira → powiadomienie → Linear → analiza → komentarz w Jira</p>
        </div>
        <div className="flex shrink-0 gap-2 max-[600px]:w-full">
          <Button type="button" variant="outline" className={cn(actionButton, "bg-card")} onClick={leave}>
            <SlidersHorizontal aria-hidden strokeWidth={1.6} />
            Reguły Jira
          </Button>
          {latest?.enabled ? (
            <Button type="button" className={actionButton} disabled={check.isPending} onClick={onCheck}>
              <Clock aria-hidden strokeWidth={1.6} />
              Sprawdź teraz
            </Button>
          ) : null}
        </div>
      </div>

      {stale ? (
        <div
          role="alert"
          aria-label="Konflikt wersji"
          className="mb-4 grid justify-items-start gap-2 rounded-[7px] border border-warning/30 bg-warning-surface p-3 text-[11px] leading-[1.7] text-warning"
        >
          <p>
            {conflict
              ? "Ktoś zmienił tę regułę, gdy ją edytowałeś. Twoje zmiany nie zostały zapisane i nadal są w formularzu."
              : "Ktoś zmienił tę regułę od czasu otwarcia formularza. Zapis Twoich zmian zostałby odrzucony."}{" "}
            Wczytanie aktualnej wersji usunie niezapisane zmiany z formularza.
          </p>
          <Button type="button" variant="outline" size="sm" className={cn(smallButton, "bg-card")} onClick={() => void reload()}>
            Wczytaj aktualną wersję
          </Button>
        </div>
      ) : null}

      <form
        noValidate
        onSubmit={onSubmit}
        className="grid grid-cols-[minmax(0,1.4fr)_minmax(280px,0.9fr)] items-start gap-6 max-[850px]:grid-cols-1"
      >
        <div className="overflow-hidden rounded-[10px] border bg-card">
          <Section
            step={1}
            title="Co i kiedy sprawdzać"
            subtitle="Wybierz źródło zgłoszeń i częstotliwość."
            aside={
              latest ? (
                <RuleSwitch
                  rule={latest}
                  busy={busy}
                  blockedReasonId={activationBlock ? activationReasonId : undefined}
                  onToggle={() => (on ? onPause() : requestActivation())}
                />
              ) : (
                <span className="ml-auto text-[11px] text-muted-foreground">Nowa reguła — zapis jej nie włącza</span>
              )
            }
          >
            <div className="grid grid-cols-2 gap-4 max-[600px]:grid-cols-1">
              <div className={cn(field, "col-span-full")}>
                <label htmlFor={f("name")}>Nazwa reguły</label>
                <input
                  id={f("name")}
                  className={input}
                  aria-invalid={nameError ? true : undefined}
                  aria-describedby={ids(nameError && `${f("name")}-error`)}
                  {...register("name")}
                />
                <FieldMessage id={`${f("name")}-error`} message={nameError} />
              </div>

              <SelectField
                id={f("project")}
                label="Projekt"
                value={values.project_id}
                placeholder="Wybierz projekt"
                loading={projects.isPending}
                options={(projects.data ?? []).map((project) => ({ value: project.id, label: project.display_name || project.slug }))}
                disabled={activated}
                error={fieldError("project_id")}
                hint={activated ? "Po pierwszej aktywacji projektu nie można zmienić." : undefined}
                onChange={(value) => {
                  set("project_id", value);
                  set("linear_team_id", "");
                  set("linear_project_id", "");
                  set("linear_todo_state_id", "");
                  set("linear_hold_label_id", "");
                }}
              />

              <SelectField
                id={f("jira")}
                label="Połączenie Jira"
                value={values.jira_connection_id}
                placeholder="Wybierz połączenie"
                loading={connectionsPending}
                options={connectionsOf(connections, "jira_cloud")}
                disabled={activated}
                error={fieldError("jira_connection_id")}
                onChange={(value) => {
                  set("jira_connection_id", value);
                  set("source_id", "");
                  set("priority_ids", []);
                }}
              >
                {connectionsError ? (
                  <LoadError
                    text="Nie udało się pobrać połączeń."
                    detail="Sprawdź połączenie z serwerem Harmony."
                    retryLabel="Ponów pobieranie połączeń"
                    onRetry={() => void refetchConnections()}
                  />
                ) : null}
              </SelectField>

              <fieldset className={field}>
                <legend className="mb-2">Źródło</legend>
                <div className="flex flex-wrap gap-x-[15px] gap-y-2 py-[5px]">
                  {(["board", "filter"] as const).map((type) => (
                    <label key={type} className={checkRow}>
                      <input
                        type="radio"
                        name={f("source-type")}
                        className={checkbox}
                        checked={values.source_type === type}
                        onChange={() => {
                          set("source_type", type);
                          set("source_id", "");
                        }}
                      />
                      {type === "board" ? "Tablica" : "Zapisany filtr"}
                    </label>
                  ))}
                </div>
              </fieldset>

              <SourcePicker
                key={`${values.jira_connection_id}-${values.source_type}`}
                id={f("source")}
                connectionId={values.jira_connection_id}
                sourceType={values.source_type}
                value={values.source_id}
                error={fieldError("source_id")}
                onChange={(value, name) => {
                  set("source_id", value);
                  setPickedSource(name ? { id: value, name } : null);
                }}
              />

              <div className={field}>
                <label htmlFor={f("interval")}>Sprawdzaj co</label>
                <div className="flex gap-2">
                  <input
                    id={f("interval")}
                    type="text"
                    inputMode="decimal"
                    className={input}
                    aria-invalid={intervalError ? true : undefined}
                    aria-describedby={ids(`${f("interval")}-hint`, intervalError && `${f("interval")}-error`)}
                    {...register("interval_value")}
                  />
                  <select
                    aria-label="Jednostka"
                    className={cn(input, "w-auto")}
                    value={values.interval_unit}
                    onChange={(event) => set("interval_unit", event.target.value as IntervalUnit)}
                  >
                    {(Object.keys(UNIT_LABEL) as IntervalUnit[]).map((unit) => (
                      <option key={unit} value={unit}>
                        {UNIT_LABEL[unit]}
                      </option>
                    ))}
                  </select>
                </div>
                <div role="group" aria-label="Szybki wybór" className="flex flex-wrap gap-1.5">
                  {INTERVAL_PRESET_MINUTES.map((minutes) => {
                    const pressed = interval.ok && interval.seconds === minutes * 60;
                    return (
                      <button
                        key={minutes}
                        type="button"
                        aria-pressed={pressed}
                        className={cn(
                          "rounded-[6px] border px-2 py-1 text-[10px] outline-none focus-visible:ring-2 focus-visible:ring-ring/50",
                          pressed ? "border-primary bg-accent text-primary" : "bg-card hover:border-primary hover:text-primary",
                        )}
                        onClick={() => {
                          set("interval_value", String(minutes));
                          set("interval_unit", "minutes");
                        }}
                      >
                        {minutes} min
                      </button>
                    );
                  })}
                </div>
                <small id={`${f("interval")}-hint`} className={hint}>
                  {interval.ok ? <span>= {interval.seconds} s</span> : null}
                  {interval.ok ? " · " : null}
                  Od 60 s do 24 godz. Częstotliwość można zmienić niezależnie dla każdej reguły.
                </small>
                <FieldMessage id={`${f("interval")}-error`} message={intervalError} />
              </div>

              <fieldset className={field} aria-describedby={ids(priorityError && `${f("priorities")}-error`)}>
                <legend className="mb-2">Priorytety</legend>
                {!values.jira_connection_id ? <small className={hint}>Najpierw wybierz połączenie Jira.</small> : null}
                {priorities.isPending && values.jira_connection_id ? <small className={hint}>Wczytywanie priorytetów…</small> : null}
                {priorities.isError ? (
                  <LoadError
                    text="Nie udało się pobrać priorytetów z Jira."
                    detail={automationErrorMessage(priorities.error)}
                    retryLabel="Ponów pobieranie priorytetów"
                    onRetry={() => void priorities.refetch()}
                  />
                ) : null}
                {priorities.isSuccess ? (
                  <div className="flex flex-wrap gap-x-[15px] gap-y-2 py-[5px]">
                    {[...priorityList.map((entry) => ({ id: entry.id, name: entry.name })), ...unknownPriorities.map((id) => ({ id, name: "nie ma w Jira" }))].map(
                      (entry) => (
                        <label key={entry.id} className={checkRow}>
                          <input
                            type="checkbox"
                            className={checkbox}
                            value={entry.id}
                            checked={values.priority_ids.includes(entry.id)}
                            onChange={(event) => togglePriority(entry.id, event.target.checked)}
                          />
                          {entry.name} <span className="text-[10px] text-muted-foreground">ID {entry.id}</span>
                        </label>
                      ),
                    )}
                  </div>
                ) : null}
                <FieldMessage id={`${f("priorities")}-error`} message={priorityError} />
              </fieldset>
            </div>

            {on && sourceChanged ? (
              <p className="mt-[15px] flex gap-2 rounded-[7px] border border-warning/30 bg-warning-surface p-3 text-[11px] leading-[1.7] text-warning">
                <TriangleAlert aria-hidden className="mt-0.5 size-3.5 shrink-0" strokeWidth={1.8} />
                Zmiana źródła lub priorytetów wyłączy regułę do czasu nowego skanu bazowego. Po zapisie aktywuj ją ponownie;
                utworzone już sprawy zostaną.
              </p>
            ) : null}

            <fieldset className="mt-[19px] grid gap-2 text-[11px]">
              <legend className="mb-2">Istniejące zgłoszenia przy aktywacji</legend>
              {(
                [
                  [
                    "new_matches_only",
                    "Tylko nowe dopasowania",
                    "Pasujące już teraz zgłoszenia trafią do stanu początkowego — bez powiadomień, zadań i analizy.",
                  ],
                  [
                    "include_existing",
                    "Importuj istniejące zgłoszenia",
                    "Każde pasujące teraz zgłoszenie dostanie sprawę, zadanie w Linear, powiadomienia i analizę. Przed aktywacją zobaczysz ich liczbę.",
                  ],
                ] as const
              ).map(([policy, label, description]) => (
                <label key={policy} className="flex items-start gap-2 leading-[1.6]">
                  <input
                    type="radio"
                    name={f("policy")}
                    className={cn(checkbox, "mt-0.5")}
                    checked={values.initial_policy === policy}
                    disabled={activated}
                    aria-labelledby={`${f(policy)}-label`}
                    aria-describedby={`${f(policy)}-description`}
                    onChange={() => set("initial_policy", policy)}
                  />
                  <span>
                    <span id={`${f(policy)}-label`}>{label}</span>
                    <small id={`${f(policy)}-description`} className={cn(hint, "block")}>
                      {description}
                    </small>
                  </span>
                </label>
              ))}
              {activated ? <small className={hint}>Polityki istniejących zgłoszeń nie można zmienić po pierwszej aktywacji.</small> : null}
            </fieldset>

            <Note icon="check">
              Uruchom analizę, gdy zgłoszenie pierwszy raz spełni warunki — także po podniesieniu priorytetu. Kolejne
              sprawdzenia nie powielają tej samej sprawy. Sprawdzanie co interwał może nie zauważyć priorytetu, który
              pojawił się i zniknął między dwoma odczytami.
            </Note>
          </Section>

          <Section step={2} title="Gdzie przekazać sprawę" subtitle="Powiązane zadanie pozwala śledzić dalszą pracę.">
            {!values.project_id ? (
              <p className={hint}>Najpierw wybierz projekt — zespoły i projekty Linear pochodzą z jego połączenia.</p>
            ) : linear.isError ? (
              <LoadError
                text="Nie udało się pobrać opcji Linear."
                detail={automationErrorMessage(linear.error)}
                retryLabel="Ponów pobieranie opcji Linear"
                onRetry={() => void linear.refetch()}
              />
            ) : (
              <div className="grid grid-cols-2 gap-4 max-[600px]:grid-cols-1">
                <SelectField
                  id={f("team")}
                  label="Zespół Linear"
                  value={values.linear_team_id}
                  placeholder="Wybierz zespół"
                  loading={linear.isPending}
                  options={teams.map((entry) => ({ value: entry.id, label: `${entry.name} (${entry.key})` }))}
                  disabled={activated}
                  error={fieldError("linear_team_id")}
                  onChange={onTeam}
                />
                <SelectField
                  id={f("linear-project")}
                  label="Projekt Linear"
                  value={values.linear_project_id}
                  placeholder={values.linear_team_id ? "Wybierz projekt" : "Najpierw wybierz zespół"}
                  loading={linear.isPending}
                  options={linearProjects.map((entry) => ({ value: entry.id, label: entry.name }))}
                  disabled={activated || !values.linear_team_id}
                  error={fieldError("linear_project_id")}
                  onChange={(value) => set("linear_project_id", value)}
                />

                <div className={field}>
                  <label htmlFor={f("todo")}>Status początkowy</label>
                  {team && !team.todo_state_id ? (
                    <p className="text-[10px] leading-[1.6] text-destructive">
                      Zespół {team.name} nie ma stanu o nazwie Todo. Dodaj go w Linear — bez niego reguły nie można zapisać ani
                      aktywować.
                    </p>
                  ) : null}
                  <input
                    id={f("todo")}
                    readOnly
                    className={input}
                    value={values.linear_todo_state_id ? "Todo" : ""}
                    placeholder="Stan Todo wybranego zespołu"
                    aria-invalid={todoError ? true : undefined}
                    aria-describedby={ids(`${f("todo")}-hint`, todoError && `${f("todo")}-error`)}
                  />
                  <small id={`${f("todo")}-hint`} className={hint}>
                    {values.linear_todo_state_id ? <span>ID stanu: {values.linear_todo_state_id}</span> : "Zadanie trafia do stanu o dokładnej nazwie Todo."}
                  </small>
                  {team && team.todo_state_id && values.linear_todo_state_id && team.todo_state_id !== values.linear_todo_state_id && !activated ? (
                    <Button type="button" variant="outline" size="sm" className={cn(smallButton, "bg-card")} onClick={() => onTeam(team.id)}>
                      Użyj bieżących identyfikatorów zespołu
                    </Button>
                  ) : null}
                  <FieldMessage id={`${f("todo")}-error`} message={todoError} />
                </div>

                <div className={field}>
                  <span>Etykieta ochronna</span>
                  {values.linear_hold_label_id ? (
                    <p className="grid gap-0.5 rounded-[6px] border bg-background px-[11px] py-2.5 text-xs">
                      {holdName}
                      <span className={hint}>ID etykiety: {values.linear_hold_label_id}</span>
                    </p>
                  ) : values.linear_team_id ? (
                    <>
                      <p className={hint}>
                        Zespół nie ma etykiety {holdName}. Harmony oznacza nią zadania, aby agent nie rozpoczął implementacji.
                      </p>
                      {activated ? null : (
                        <Button
                          type="button"
                          variant="outline"
                          size="sm"
                          className={cn(smallButton, "bg-card")}
                          disabled={holdLabel.isPending}
                          onClick={() => setConfirmLabel(true)}
                        >
                          Utwórz etykietę ochronną
                        </Button>
                      )}
                    </>
                  ) : (
                    <p className={hint}>Etykieta chroni zadanie przed automatyczną implementacją.</p>
                  )}
                  {holdLabel.isError ? (
                    <span role="alert" className="text-[10px] leading-[1.6] text-destructive">
                      {automationErrorMessage(holdLabel.error)}
                    </span>
                  ) : null}
                  <FieldMessage id={`${f("label")}-error`} message={labelError} />
                </div>
              </div>
            )}
            {linear.data?.truncated ? (
              <p className={cn(hint, "mt-3")}>
                Linear zwrócił niepełną listę zespołów lub projektów. Jeśli czegoś brakuje, ogranicz zakres tokenu projektu.
              </p>
            ) : null}
          </Section>

          <Section step={3} title="Powiadomienia i wynik" subtitle="Alert od razu, komentarz po zakończeniu analizy.">
            <div className="grid grid-cols-2 gap-4 max-[600px]:grid-cols-1">
              {(
                [
                  {
                    channel: "email",
                    toggle: "Wysyłaj e-mail",
                    connection: "Połączenie SMTP",
                    kind: "smtp",
                    recipients: "Adresaci e-mail",
                    help: "Jeden adres w wierszu, najwyżej 10.",
                  },
                  {
                    channel: "sms",
                    toggle: "Wysyłaj SMS",
                    connection: "Połączenie SMSAPI",
                    kind: "smsapi",
                    recipients: "Numery telefonów",
                    help: "Jeden numer w wierszu, z prefiksem kraju (np. +48 600 100 200), najwyżej 10. Każdy SMS jest płatny.",
                  },
                ] as const
              ).map((entry) => {
                const enabledKey = `${entry.channel}_enabled` as const;
                const connectionKey = `${entry.channel}_connection_id` as const;
                const recipientsKey = `${entry.channel}_recipients` as const;
                const recipientsError = fieldError(recipientsKey);
                const recipientsId = f(`${entry.channel}-recipients`);
                return (
                  <div key={entry.channel} className="grid content-start gap-3">
                    <label className={checkRow}>
                      <input type="checkbox" className={checkbox} {...register(enabledKey)} />
                      {entry.toggle}
                    </label>
                    {values[enabledKey] ? (
                      <>
                        <SelectField
                          id={f(`${entry.channel}-connection`)}
                          label={entry.connection}
                          value={values[connectionKey]}
                          placeholder="Wybierz połączenie"
                          loading={connectionsPending}
                          options={connectionsOf(connections, entry.kind)}
                          error={fieldError(connectionKey)}
                          onChange={(value) => set(connectionKey, value)}
                        />
                        <div className={field}>
                          <label htmlFor={recipientsId}>{entry.recipients}</label>
                          <textarea
                            id={recipientsId}
                            rows={3}
                            className={cn(input, "resize-y")}
                            aria-invalid={recipientsError ? true : undefined}
                            aria-describedby={ids(`${recipientsId}-hint`, recipientsError && `${recipientsId}-error`)}
                            {...register(recipientsKey)}
                          />
                          <small id={`${recipientsId}-hint`} className={hint}>
                            {entry.help}
                          </small>
                          <FieldMessage id={`${recipientsId}-error`} message={recipientsError} />
                        </div>
                      </>
                    ) : null}
                  </div>
                );
              })}
            </div>
            {!values.email_enabled && !values.sms_enabled ? (
              <p className={cn(hint, "mt-3")}>Oba kanały są wyłączone — nowe sprawy pojawią się tylko w Centrum spraw.</p>
            ) : null}
            <Note icon="shield">
              Tryb: tylko analiza. Agent publikuje ustalenia w Jira. Nie rozpoczyna przygotowania naprawy ani zmian w
              repozytorium.
            </Note>
          </Section>
        </div>

        <aside className="sticky top-5 max-[850px]:static">
          <section aria-labelledby={f("preview-title")} className="rounded-[10px] border bg-card p-[23px]">
            <p className="mb-[13px] text-[10px] font-bold tracking-[1.4px] text-muted-foreground uppercase">Podgląd działania</p>
            <h2 id={f("preview-title")} className="mb-4 text-[15px] font-semibold">
              Twoja reguła, prostym językiem
            </h2>
            <RuleSummary
              intervalText={interval.ok ? formatInterval(interval.seconds) : null}
              sourceType={values.source_type}
              sourceLabel={sourceLabel}
              priorityNames={priorityNames}
              email={values.email_enabled}
              sms={values.sms_enabled}
              policy={values.initial_policy}
            />

            <div className="mt-3 grid gap-3">
              <Button
                type="button"
                variant="outline"
                className={cn(panelButton, "border-primary bg-card text-primary")}
                disabled={Boolean(previewBlock) || preview.isPending}
                aria-describedby={previewBlock ? previewReasonId : undefined}
                onClick={runPreview}
              >
                {preview.isPending ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : <FlaskConical aria-hidden strokeWidth={1.6} />}
                Przetestuj na zapisanej wersji
              </Button>
              {previewBlock ? (
                <small id={previewReasonId} className={hint}>
                  {previewBlock}
                </small>
              ) : null}

              <Button type="submit" className={panelButton} disabled={saving}>
                {saving ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : <Check aria-hidden strokeWidth={1.6} />}
                Zapisz regułę
              </Button>

              {latest && on ? (
                <Button type="button" variant="outline" className={cn(panelButton, "bg-card")} disabled={busy} onClick={onPause}>
                  <Pause aria-hidden strokeWidth={1.6} />
                  Wstrzymaj regułę
                </Button>
              ) : null}
              {latest && !on ? (
                <Button
                  type="button"
                  variant="outline"
                  className={cn(panelButton, "bg-card")}
                  disabled={Boolean(activationBlock) || busy}
                  aria-describedby={activationBlock ? activationReasonId : undefined}
                  onClick={requestActivation}
                >
                  {activate.isPending ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : null}
                  {firstBaseline ? "Aktywuj regułę" : "Wznów regułę"}
                </Button>
              ) : null}
              {latest && !on && activationBlock ? (
                <small id={activationReasonId} className={hint}>
                  {activationBlock}
                </small>
              ) : null}
            </div>

            <p
              role="status"
              aria-live="polite"
              className={cn("mt-3 text-[11px] leading-[1.6]", notice?.tone === "warning" ? "text-warning" : "text-success")}
            >
              {notice?.text ?? ""}
            </p>
            <FailureAlert failure={saveFailure} />
            <FailureAlert failure={actionFailure} />

            {preview.isError ? (
              <FailureAlert failure={{ title: "Podgląd się nie udał", messages: [automationErrorMessage(preview.error)] }} />
            ) : null}
            {previewData ? (
              <PreviewResult
                preview={previewData}
                policy={latest?.initial_policy ?? values.initial_policy}
                firstBaseline={firstBaseline}
                projects={projects.data}
              />
            ) : preview.data ? (
              <p className={cn(hint, "mt-3")}>Konfiguracja zmieniła się od ostatniego podglądu. Uruchom go ponownie.</p>
            ) : null}

            {latest ? (
              <dl className="mt-4 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 border-t pt-3 text-[11px] leading-[1.6]">
                <dt className="text-muted-foreground">Ostatni sukces</dt>
                <dd>{formatRuleTime(latest.last_success_at)}</dd>
                <dt className="text-muted-foreground">Następne sprawdzenie</dt>
                <dd>{formatRuleTime(latest.next_poll_at)}</dd>
                {latest.last_error_code ? (
                  <>
                    <dt className="text-muted-foreground">Ostatni błąd</dt>
                    <dd className="text-destructive">{ruleErrorMessage(latest.last_error_code)}</dd>
                  </>
                ) : null}
              </dl>
            ) : null}
          </section>
          <p className="px-[3px] py-4 text-[10px] leading-[1.8] text-muted-foreground max-[600px]:text-[11px]">
            Podgląd sprawdza zapisaną wersję reguły w Jira i niczego nie wysyła. Aktywacja jest osobnym, potwierdzanym
            krokiem.
          </p>
        </aside>
      </form>

      {latest ? (
        <ActivationDialog
          open={confirmActivation}
          onOpenChange={setConfirmActivation}
          rule={latest}
          sourceLabel={sourceLabel ?? `ID ${latest.source_id}`}
          preview={previewData}
          projects={projects.data}
          pending={activate.isPending}
          onConfirm={onActivate}
        />
      ) : null}

      <Confirm
        open={confirmLeave}
        onOpenChange={setConfirmLeave}
        title="Porzucić niezapisane zmiany?"
        cancelLabel="Zostań w edycji"
        confirmLabel="Porzuć zmiany"
        onConfirm={() => {
          setConfirmLeave(false);
          reset();
          navigate("/automations");
        }}
      >
        <p>Zmiany w tej regule nie zostały zapisane. Jeśli wyjdziesz, przepadną.</p>
      </Confirm>

      <Confirm
        open={confirmLabel}
        onOpenChange={setConfirmLabel}
        title="Utworzyć etykietę w Linear?"
        cancelLabel="Anuluj"
        confirmLabel="Utwórz etykietę"
        pending={holdLabel.isPending}
        onConfirm={onCreateLabel}
      >
        <p>
          Harmony utworzy w zespole {team?.name ?? "Linear"} etykietę {holdName} albo użyje istniejącej o tej nazwie. Etykieta
          oznacza zadania z tej automatyzacji, aby agent nie rozpoczął ich implementacji bez zgody.
        </p>
      </Confirm>
    </div>
  );
}
