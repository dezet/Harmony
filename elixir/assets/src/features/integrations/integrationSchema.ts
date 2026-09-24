import * as yup from "yup";
import type {
  IntegrationConnection,
  IntegrationConnectionInput,
  IntegrationConnectionPatch,
  IntegrationKind,
} from "@/types/contract";

// Connection form (spec §7.2, §10.2, §10.3, §12). The form keeps one flat set
// of text fields; `toConnectionInput` sends only the settings of the chosen
// kind (and of the chosen Jira mode), `connectionPatch` only what changed. The
// secret is write-only: it always starts empty, an empty value keeps the
// stored one and it is sent only when the operator typed something. The
// backend validates the same rules again (strict whitelist per kind).

export type JiraAuthMode = "classic" | "scoped";
export type TlsMode = "starttls" | "tls";

export interface IntegrationFormValues {
  name: string;
  secret: string;
  site_url: string;
  auth_mode: JiraAuthMode;
  account_email: string;
  cloud_id: string;
  host: string;
  port: string;
  tls_mode: TlsMode;
  username: string;
  from_email: string;
  from_name: string;
  message_id_domain: string;
  sender: string;
}

export type SettingField = Exclude<keyof IntegrationFormValues, "name" | "secret">;

export const MAX_NAME_LENGTH = 100;
export const MAX_SENDER_LENGTH = 11;
export const DEFAULT_SMTP_PORT = 587;

const ATLASSIAN_SITE = /^https:\/\/[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.atlassian\.net\/?$/;
const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const ADDRESS = /^[A-Za-z0-9._%+'-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$/;
const DOMAIN = /^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$/;
const HOST = /^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/;
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f]/;
const DIGITS = /^[0-9]+$/;

/** Settings keys of each kind (backend `@input_settings`); a Jira mode sends only its own identity key. */
export function settingFields(kind: IntegrationKind, authMode: JiraAuthMode): SettingField[] {
  if (kind === "jira_cloud") return ["site_url", "auth_mode", authMode === "classic" ? "account_email" : "cloud_id"];
  if (kind === "smtp") return ["host", "port", "tls_mode", "username", "from_email", "from_name", "message_id_domain"];
  return ["sender"];
}

const text = () => yup.string().defined().default("");
type TextSchema = ReturnType<typeof text>;
const singleLine = (message: string) =>
  text().test("single-line", message, (value) => value.trim() !== "" && !CONTROL.test(value));

/** Host comparison of the backend allowlist check: trimmed and case-insensitive. */
export function isAllowedHost(allowed: readonly string[], host: string): boolean {
  const normalized = host.trim().toLowerCase();
  return normalized !== "" && allowed.some((entry) => entry.trim().toLowerCase() === normalized);
}

/** Normalized site URL: trimmed, lower-case, without a trailing slash. */
export function normalizeSiteUrl(value: string): string {
  return value.trim().toLowerCase().replace(/\/+$/, "");
}

/**
 * `smtpAllowedHosts` is the runtime `intake.smtp_allowed_hosts` (null while
 * it loads): an SMTP host must be one of them (spec §12).
 */
export function integrationFormSchema(kind: IntegrationKind, smtpAllowedHosts: readonly string[] | null = null) {
  const on = (kinds: IntegrationKind[], schema: TextSchema): TextSchema => (kinds.includes(kind) ? schema : text());

  return yup.object({
    name: text()
      .test("name", "Podaj nazwę połączenia.", (value) => value.trim() !== "")
      .test("name-length", `Nazwa może mieć najwyżej ${MAX_NAME_LENGTH} znaków.`, (value) => value.trim().length <= MAX_NAME_LENGTH),
    secret: text(),
    site_url: on(
      ["jira_cloud"],
      text().test("site", "Adres musi mieć postać https://<nazwa>.atlassian.net.", (value) =>
        ATLASSIAN_SITE.test(value.trim().toLowerCase()),
      ),
    ),
    auth_mode: yup.mixed<JiraAuthMode>().oneOf(["classic", "scoped"]).defined(),
    account_email: text().when("auth_mode", {
      is: (mode: JiraAuthMode) => kind === "jira_cloud" && mode === "classic",
      then: () => text().test("email", "Podaj e-mail konta Atlassian, do którego należy token.", (value) => ADDRESS.test(value.trim())),
    }),
    cloud_id: text().when("auth_mode", {
      is: (mode: JiraAuthMode) => kind === "jira_cloud" && mode === "scoped",
      then: () =>
        text().test("cloud", "Cloud ID ma postać UUID, np. 0e4f7b0c-3a51-4d5c-9c2a-6f1e2d3c4b5a.", (value) => UUID.test(value.trim())),
    }),
    host: on(
      ["smtp"],
      text()
        .test("host", "Wybierz host SMTP z listy dozwolonych.", (value) => HOST.test(value.trim()))
        .test(
          "allowed-host",
          "Wybierz host z listy dozwolonych hostów SMTP (intake.smtp_allowed_hosts).",
          (value) => smtpAllowedHosts === null || isAllowedHost(smtpAllowedHosts, value),
        ),
    ),
    port: on(
      ["smtp"],
      text().test("port", "Port to liczba całkowita od 1 do 65 535.", (value) => {
        const trimmed = value.trim();
        return DIGITS.test(trimmed) && Number(trimmed) >= 1 && Number(trimmed) <= 65_535;
      }),
    ),
    tls_mode: yup.mixed<TlsMode>().oneOf(["starttls", "tls"]).defined(),
    username: on(["smtp"], singleLine("Podaj użytkownika SMTP.")),
    from_email: on(["smtp"], text().test("from", "Podaj adres e-mail nadawcy.", (value) => ADDRESS.test(value.trim()))),
    from_name: on(["smtp"], singleLine("Podaj nazwę nadawcy.")),
    message_id_domain: on(
      ["smtp"],
      text().test("domain", "Podaj domenę, np. example.com.", (value) => DOMAIN.test(value.trim())),
    ),
    sender: on(
      ["smsapi"],
      singleLine(`Podaj zatwierdzoną nazwę nadawcy, do ${MAX_SENDER_LENGTH} znaków.`).test(
        "sender-length",
        `Nazwa nadawcy może mieć do ${MAX_SENDER_LENGTH} znaków.`,
        (value) => value.trim().length <= MAX_SENDER_LENGTH,
      ),
    ),
  });
}

export function emptyFormValues(kind: IntegrationKind): IntegrationFormValues {
  return {
    name: "",
    secret: "",
    site_url: "",
    auth_mode: "classic",
    account_email: "",
    cloud_id: "",
    host: "",
    port: kind === "smtp" ? String(DEFAULT_SMTP_PORT) : "",
    tls_mode: "starttls",
    username: "",
    from_email: "",
    from_name: kind === "smtp" ? "Harmony" : "",
    message_id_domain: "",
    sender: "",
  };
}

function settingText(settings: Record<string, unknown>, key: string): string {
  const value = settings[key];
  return typeof value === "string" || typeof value === "number" ? String(value) : "";
}

/** Form values of a stored connection; the secret field is always empty. */
export function formValuesFromConnection(connection: IntegrationConnection): IntegrationFormValues {
  const base = emptyFormValues(connection.kind);
  const settings = connection.settings ?? {};
  const values: IntegrationFormValues = { ...base, name: connection.name, secret: "" };
  for (const key of settingFields(connection.kind, "classic").concat(settingFields(connection.kind, "scoped"))) {
    const stored = settingText(settings, key);
    if (stored !== "") Object.assign(values, { [key]: stored });
  }
  if (values.auth_mode !== "classic" && values.auth_mode !== "scoped") values.auth_mode = "classic";
  if (values.tls_mode !== "starttls" && values.tls_mode !== "tls") values.tls_mode = "starttls";
  return values;
}

function settingValue(key: SettingField, values: IntegrationFormValues): string | number {
  if (key === "port") return Number(values.port.trim());
  if (key === "site_url") return normalizeSiteUrl(values.site_url);
  if (key === "auth_mode" || key === "tls_mode") return values[key];
  return values[key].trim();
}

function settingsOf(kind: IntegrationKind, values: IntegrationFormValues): Record<string, string | number> {
  const settings: Record<string, string | number> = {};
  for (const key of settingFields(kind, values.auth_mode)) settings[key] = settingValue(key, values);
  return settings;
}

/** ConnectionInput of validated values; the secret only when something was typed. */
export function toConnectionInput(kind: IntegrationKind, values: IntegrationFormValues): IntegrationConnectionInput {
  const input: IntegrationConnectionInput = { kind, name: values.name.trim(), settings: settingsOf(kind, values) };
  if (values.secret.trim() !== "") input.secret = values.secret;
  return input;
}

/**
 * Only the fields that differ from the connection the form was loaded from:
 * the backend merges `settings`, so only changed keys are sent. `version` is
 * added by the caller.
 */
export function connectionPatch(
  connection: IntegrationConnection,
  values: IntegrationFormValues,
): Omit<IntegrationConnectionPatch, "version"> {
  const patch: Omit<IntegrationConnectionPatch, "version"> = {};
  const name = values.name.trim();
  if (name !== connection.name) patch.name = name;

  const stored = connection.settings ?? {};
  const changed: Record<string, string | number> = {};
  for (const [key, value] of Object.entries(settingsOf(connection.kind, values))) {
    const current = key === "site_url" && typeof stored[key] === "string" ? normalizeSiteUrl(stored[key]) : stored[key];
    if (current !== value) changed[key] = value;
  }
  if (Object.keys(changed).length > 0) patch.settings = changed;
  if (values.secret.trim() !== "") patch.secret = values.secret;
  return patch;
}
