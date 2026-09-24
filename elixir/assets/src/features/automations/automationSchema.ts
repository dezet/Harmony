import * as yup from "yup";
import type {
  AutomationInitialPolicy,
  AutomationRule,
  AutomationRuleInput,
  AutomationSourceType,
} from "@/types/contract";

// Rule form (spec §7.1, §11.2). The form keeps what the operator typed: the
// interval as a number plus a unit and the recipients as one text per channel.
// `toRuleInput` turns it into the exact RuleInput; nothing is rounded, a value
// that does not give whole seconds is rejected instead. The backend validates
// the same rules again.

export type IntervalUnit = "seconds" | "minutes" | "hours";

export const UNIT_SECONDS: Record<IntervalUnit, number> = { seconds: 1, minutes: 60, hours: 3600 };

export const UNIT_LABEL: Record<IntervalUnit, string> = { seconds: "sekundy", minutes: "minuty", hours: "godziny" };

export const INTERVAL_PRESET_MINUTES = [1, 5, 10, 15, 30, 60] as const;

export const MIN_INTERVAL_SECONDS = 60;
export const MAX_INTERVAL_SECONDS = 86_400;
export const MAX_RECIPIENTS = 10;
export const MAX_PRIORITIES = 100;
export const MAX_NAME_LENGTH = 100;

export type IntervalParse = { ok: true; seconds: number } | { ok: false; reason: "empty" | "invalid" | "fraction" };

const DECIMAL = /^(\d+)(?:[.,](\d+))?$/;
const DIGITS = /^[0-9]+$/;

/**
 * Exact decimal arithmetic: "1,1" minutes is 11/10 × 60 = 66 s, never
 * 66.00000000000001. A value that does not give whole seconds is refused.
 */
export function parseIntervalSeconds(raw: string, unit: IntervalUnit): IntervalParse {
  const text = raw.trim();
  if (text === "") return { ok: false, reason: "empty" };
  const match = DECIMAL.exec(text);
  if (!match) return { ok: false, reason: "invalid" };
  const [, whole, fraction = ""] = match;
  if (whole.length + fraction.length > 12) return { ok: false, reason: "invalid" };

  const scale = 10 ** fraction.length;
  const scaled = Number(whole + fraction) * UNIT_SECONDS[unit];
  if (scaled % scale !== 0) return { ok: false, reason: "fraction" };
  return { ok: true, seconds: scaled / scale };
}

/** The largest unit that divides the interval without a remainder. */
export function splitInterval(seconds: number): { value: string; unit: IntervalUnit } {
  if (seconds % 3600 === 0) return { value: String(seconds / 3600), unit: "hours" };
  if (seconds % 60 === 0) return { value: String(seconds / 60), unit: "minutes" };
  return { value: String(seconds), unit: "seconds" };
}

/** Exact human form of an interval: "5 min", "1 godz.", "90 s". */
export function formatInterval(seconds: number): string {
  const { value, unit } = splitInterval(seconds);
  if (unit === "hours") return `${value} godz.`;
  if (unit === "minutes") return `${value} min`;
  return `${value} s`;
}

export function parseRecipients(text: string): string[] {
  return text
    .split(/[\n,;]+/)
    .map((entry) => entry.trim())
    .filter((entry) => entry !== "");
}

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const E164 = /^\+[1-9]\d{6,14}$/;

// Same normalization as the backend (Smsapi.normalize_phone/1): separators are
// dropped and a leading 00 becomes +. A number without a country prefix is refused.
function isPhone(value: string): boolean {
  const compact = value.replace(/[\s().-]/g, "");
  const candidate = compact.startsWith("00") ? `+${compact.slice(2)}` : compact;
  return E164.test(candidate);
}

export interface AutomationFormValues {
  name: string;
  project_id: string;
  jira_connection_id: string;
  source_type: AutomationSourceType;
  source_id: string;
  priority_ids: string[];
  interval_value: string;
  interval_unit: IntervalUnit;
  initial_policy: AutomationInitialPolicy;
  linear_team_id: string;
  linear_project_id: string;
  linear_todo_state_id: string;
  linear_hold_label_id: string;
  email_enabled: boolean;
  email_connection_id: string;
  email_recipients: string;
  sms_enabled: boolean;
  sms_connection_id: string;
  sms_recipients: string;
}

function intervalError(value: string, unit: IntervalUnit): string | null {
  const parsed = parseIntervalSeconds(value, unit);
  if (!parsed.ok) {
    if (parsed.reason === "empty") return "Podaj częstotliwość sprawdzania.";
    if (parsed.reason === "fraction") {
      return "Ta wartość nie daje pełnej liczby sekund, a Harmony nie zaokrągla interwału. Podaj np. liczbę sekund.";
    }
    return "Podaj liczbę dodatnią, np. 5 albo 1,5.";
  }
  if (parsed.seconds < MIN_INTERVAL_SECONDS) return "Interwał musi wynosić co najmniej 60 s (1 min).";
  if (parsed.seconds > MAX_INTERVAL_SECONDS) return "Interwał może wynosić najwyżej 86 400 s (24 godz.).";
  return null;
}

function recipientsError(text: string, channel: "email" | "sms"): string | null {
  const recipients = parseRecipients(text);
  if (recipients.length === 0) {
    return channel === "email" ? "Podaj co najmniej jednego adresata e-mail." : "Podaj co najmniej jednego adresata SMS.";
  }
  if (recipients.length > MAX_RECIPIENTS) return `Można podać najwyżej ${MAX_RECIPIENTS} adresatów.`;
  const invalid = recipients.find((entry) => (channel === "email" ? !EMAIL.test(entry) : !isPhone(entry)));
  if (invalid !== undefined) {
    return channel === "email"
      ? `Niepoprawny adres e-mail: ${invalid}.`
      : `Numer ${invalid} musi mieć prefiks kraju, np. +48 600 100 200.`;
  }
  const seen = new Set<string>();
  const duplicate = recipients.find((entry) => {
    const key = entry.toLowerCase().replace(/[\s().-]/g, "");
    if (seen.has(key)) return true;
    seen.add(key);
    return false;
  });
  return duplicate === undefined ? null : `Adresat ${duplicate} powtarza się.`;
}

function channelSchema(channel: "email" | "sms", connectionMessage: string) {
  const enabledKey = `${channel}_enabled` as const;
  return {
    connection: yup
      .string()
      .defined()
      .test("channel-connection", connectionMessage, function (value) {
        return !this.parent[enabledKey] || Boolean(value);
      }),
    recipients: yup
      .string()
      .defined()
      .test("channel-recipients", function (value) {
        if (!this.parent[enabledKey]) return true;
        const message = recipientsError(value, channel);
        return message === null ? true : this.createError({ message });
      }),
  };
}

const email = channelSchema("email", "Wybierz połączenie SMTP.");
const sms = channelSchema("sms", "Wybierz połączenie SMSAPI.");

export const automationFormSchema: yup.ObjectSchema<AutomationFormValues> = yup.object({
  name: yup
    .string()
    .defined()
    .test("name-present", "Podaj nazwę reguły.", (value) => value.trim().length > 0)
    .max(MAX_NAME_LENGTH, `Nazwa może mieć najwyżej ${MAX_NAME_LENGTH} znaków.`),
  project_id: yup.string().defined().required("Wybierz projekt."),
  jira_connection_id: yup.string().defined().required("Wybierz połączenie Jira."),
  source_type: yup.mixed<AutomationSourceType>().oneOf(["board", "filter"]).defined(),
  source_id: yup
    .string()
    .defined()
    .required("Wybierz tablicę albo zapisany filtr Jira.")
    .matches(DIGITS, "Identyfikator źródła musi składać się z cyfr."),
  priority_ids: yup
    .array(yup.string().defined().matches(DIGITS, "Identyfikator priorytetu musi składać się z cyfr."))
    .defined()
    .min(1, "Zaznacz co najmniej jeden priorytet.")
    .max(MAX_PRIORITIES, `Można zaznaczyć najwyżej ${MAX_PRIORITIES} priorytetów.`)
    .test("priorities-unique", "Priorytety nie mogą się powtarzać.", (ids) => new Set(ids).size === ids.length),
  interval_value: yup
    .string()
    .defined()
    .test("interval", function (value) {
      const message = intervalError(value, this.parent.interval_unit as IntervalUnit);
      return message === null ? true : this.createError({ message });
    }),
  interval_unit: yup.mixed<IntervalUnit>().oneOf(["seconds", "minutes", "hours"]).defined(),
  initial_policy: yup.mixed<AutomationInitialPolicy>().oneOf(["new_matches_only", "include_existing"]).defined(),
  linear_team_id: yup.string().defined().required("Wybierz zespół Linear."),
  linear_project_id: yup.string().defined().required("Wybierz projekt Linear."),
  linear_todo_state_id: yup.string().defined().required("Wybrany zespół nie ma stanu Todo."),
  linear_hold_label_id: yup.string().defined().required("Wybrany zespół nie ma etykiety ochronnej — utwórz ją."),
  email_enabled: yup.boolean().defined(),
  email_connection_id: email.connection,
  email_recipients: email.recipients,
  sms_enabled: yup.boolean().defined(),
  sms_connection_id: sms.connection,
  sms_recipients: sms.recipients,
});

export function emptyFormValues(): AutomationFormValues {
  return {
    name: "",
    project_id: "",
    jira_connection_id: "",
    source_type: "board",
    source_id: "",
    priority_ids: [],
    interval_value: "5",
    interval_unit: "minutes",
    initial_policy: "new_matches_only",
    linear_team_id: "",
    linear_project_id: "",
    linear_todo_state_id: "",
    linear_hold_label_id: "",
    email_enabled: false,
    email_connection_id: "",
    email_recipients: "",
    sms_enabled: false,
    sms_connection_id: "",
    sms_recipients: "",
  };
}

export function formValuesFromRule(rule: AutomationRule): AutomationFormValues {
  const interval = splitInterval(rule.interval_seconds);
  return {
    name: rule.name,
    project_id: rule.project_id,
    jira_connection_id: rule.jira_connection_id,
    source_type: rule.source_type,
    source_id: rule.source_id,
    priority_ids: [...rule.priority_ids],
    interval_value: interval.value,
    interval_unit: interval.unit,
    initial_policy: rule.initial_policy,
    linear_team_id: rule.linear_team_id,
    linear_project_id: rule.linear_project_id,
    linear_todo_state_id: rule.linear_todo_state_id,
    linear_hold_label_id: rule.linear_hold_label_id,
    email_enabled: rule.email_connection_id !== null,
    email_connection_id: rule.email_connection_id ?? "",
    email_recipients: rule.email_recipients.join("\n"),
    sms_enabled: rule.sms_connection_id !== null,
    sms_connection_id: rule.sms_connection_id ?? "",
    sms_recipients: rule.sms_recipients.join("\n"),
  };
}

/** RuleInput of validated form values; a disabled channel is `null` with an empty list. */
export function toRuleInput(values: AutomationFormValues): AutomationRuleInput {
  const interval = parseIntervalSeconds(values.interval_value, values.interval_unit);
  if (!interval.ok) throw new Error("interval_seconds is not a whole number of seconds");

  return {
    name: values.name.trim(),
    project_id: values.project_id,
    jira_connection_id: values.jira_connection_id,
    source_type: values.source_type,
    source_id: values.source_id.trim(),
    priority_ids: [...values.priority_ids],
    interval_seconds: interval.seconds,
    initial_policy: values.initial_policy,
    linear_team_id: values.linear_team_id,
    linear_project_id: values.linear_project_id,
    linear_todo_state_id: values.linear_todo_state_id,
    linear_hold_label_id: values.linear_hold_label_id,
    email_connection_id: values.email_enabled ? values.email_connection_id : null,
    sms_connection_id: values.sms_enabled ? values.sms_connection_id : null,
    email_recipients: values.email_enabled ? parseRecipients(values.email_recipients) : [],
    sms_recipients: values.sms_enabled ? parseRecipients(values.sms_recipients) : [],
  };
}

// Backend Rules @immutable_after_activation: sending any of these after the
// first activation is a 422, even with the stored value.
export const IMMUTABLE_AFTER_ACTIVATION: ReadonlySet<keyof AutomationRuleInput> = new Set([
  "project_id",
  "jira_connection_id",
  "linear_team_id",
  "linear_project_id",
  "linear_todo_state_id",
  "linear_hold_label_id",
  "initial_policy",
]);

// A change of any of these disables an active rule until a new baseline.
export const SOURCE_FIELDS: ReadonlySet<keyof AutomationRuleInput> = new Set(["source_type", "source_id", "priority_ids"]);

function sameValue(key: keyof AutomationRuleInput, a: unknown, b: unknown): boolean {
  if (Array.isArray(a) && Array.isArray(b)) {
    if (key === "priority_ids") return a.length === b.length && [...a].sort().join("\n") === [...b].sort().join("\n");
    return a.length === b.length && a.every((value, index) => value === b[index]);
  }
  return a === b;
}

/**
 * Only the fields that differ from the rule the form was loaded from, so the
 * PATCH never carries an unknown or an unchanged immutable field. The order of
 * priorities has no meaning and is not a change.
 */
export function rulePatch(rule: AutomationRule, input: AutomationRuleInput): Partial<AutomationRuleInput> {
  const activated = rule.activated_at !== null;
  const patch: Partial<AutomationRuleInput> = {};
  for (const key of Object.keys(input) as (keyof AutomationRuleInput)[]) {
    if (activated && IMMUTABLE_AFTER_ACTIVATION.has(key)) continue;
    if (!sameValue(key, rule[key], input[key])) Object.assign(patch, { [key]: input[key] });
  }
  return patch;
}
