import { useId, useMemo, useState, type ReactNode } from "react";
import { useForm, useWatch, type Path, type Resolver, type UseFormRegisterReturn } from "react-hook-form";
import { yupResolver } from "@hookform/resolvers/yup";
import { Info, Loader2, TriangleAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ApiError } from "@/lib/api";
import { cn } from "@/lib/utils";
import {
  connectionPatch,
  emptyFormValues,
  formValuesFromConnection,
  integrationFormSchema,
  isAllowedHost,
  MAX_NAME_LENGTH,
  MAX_SENDER_LENGTH,
  toConnectionInput,
  type IntegrationFormValues,
} from "@/features/integrations/integrationSchema";
import {
  integrationErrorMessage,
  SECRET_LABEL,
  useConnections,
  useCreateIntegration,
  useReloadIntegration,
  useUpdateIntegration,
} from "@/features/integrations/useIntegrations";
import type { IntegrationConnection, IntegrationKind } from "@/types/contract";

// Connection editor (spec §4.6, §10, §12): the parameters of one provider and
// its write-only secret. The secret input always starts empty and is never
// filled from the API (which has only `secret_state`) nor kept in browser
// storage. The form keeps the connection it was loaded from (`base`): its
// `lock_version` is the PATCH `version`, so an edit made elsewhere is a 409
// and never gets overwritten.

type FieldName = Path<IntegrationFormValues>;
type Failure = { message: string; stale: boolean; details: string[] };

const input =
  "w-full min-w-0 rounded-[6px] border bg-background px-[11px] py-2.5 text-xs text-foreground outline-none focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/50 disabled:cursor-not-allowed disabled:opacity-60 aria-invalid:border-destructive";
const field = "flex min-w-0 flex-col gap-2 text-[11px]";
const hint = "text-[10px] leading-[1.65] text-muted-foreground";
const actionButton =
  "h-auto min-h-[35px] gap-[7px] rounded-[7px] px-3 py-[9px] text-[11px] font-[550] leading-[1.3] max-[600px]:flex-1 [&_svg:not([class*='size-'])]:size-3.5";

// Server field keys (IntegrationController / Connections) and their Polish texts.
const SERVER_FIELDS: Record<string, { field: FieldName; message: string }> = {
  name: { field: "name", message: `Serwer odrzucił nazwę — użyj od 1 do ${MAX_NAME_LENGTH} znaków.` },
  secret: { field: "secret", message: "Serwer odrzucił sekret." },
  site_url: {
    field: "site_url",
    message: "Adresu witryny nie można zmienić po pierwszym użyciu połączenia. Dla innej instancji utwórz nowe połączenie.",
  },
  "settings.site_url": { field: "site_url", message: "Adres musi mieć postać https://<nazwa>.atlassian.net." },
  "settings.auth_mode": { field: "auth_mode", message: "Wybierz sposób uwierzytelniania." },
  "settings.account_email": { field: "account_email", message: "Tryb klasyczny wymaga e-maila konta Atlassian." },
  "settings.cloud_id": { field: "cloud_id", message: "Serwer odrzucił Cloud ID — podaj UUID witryny Atlassian." },
  "settings.host": {
    field: "host",
    message:
      "Tego hosta nie ma na liście dozwolonych hostów SMTP wdrożenia (intake.smtp_allowed_hosts). Poproś operatora wdrożenia o dopisanie hosta albo użyj hosta z listy.",
  },
  "settings.port": { field: "port", message: "Port to liczba całkowita od 1 do 65 535." },
  "settings.tls_mode": { field: "tls_mode", message: "Wybierz STARTTLS albo TLS." },
  "settings.username": { field: "username", message: "Serwer odrzucił użytkownika SMTP." },
  "settings.from_email": { field: "from_email", message: "Serwer odrzucił adres nadawcy." },
  "settings.from_name": { field: "from_name", message: "Serwer odrzucił nazwę nadawcy." },
  "settings.message_id_domain": { field: "message_id_domain", message: "Serwer odrzucił domenę Message-ID." },
  "settings.sender": {
    field: "sender",
    message: `Serwer odrzucił nazwę nadawcy — użyj zatwierdzonej w SMSAPI nazwy do ${MAX_SENDER_LENGTH} znaków.`,
  },
};

const FORM_LEVEL: Record<string, string> = {
  settings: "Serwer odrzucił ustawienia połączenia. Sprawdź wszystkie pola.",
  enabled: "Połączenie można włączyć dopiero po zapisaniu sekretu.",
};

function ids(...values: (string | false | null | undefined)[]): string | undefined {
  const joined = values.filter(Boolean).join(" ");
  return joined || undefined;
}

interface TextFieldProps {
  id: string;
  label: string;
  registration: UseFormRegisterReturn;
  error?: string;
  hint?: ReactNode;
  type?: "text" | "email" | "password" | "url";
  inputMode?: "numeric";
  autoComplete?: string;
  maxLength?: number;
  className?: string;
}

function TextField({ id, label, registration, error, hint: hintText, type = "text", inputMode, autoComplete = "off", maxLength, className }: TextFieldProps) {
  return (
    <div className={cn(field, className)}>
      <label htmlFor={id}>{label}</label>
      <input
        id={id}
        type={type}
        inputMode={inputMode}
        autoComplete={autoComplete}
        spellCheck={false}
        maxLength={maxLength}
        className={input}
        aria-invalid={error ? true : undefined}
        aria-describedby={ids(hintText ? `${id}-hint` : null, error ? `${id}-error` : null)}
        {...registration}
      />
      {hintText ? (
        <small id={`${id}-hint`} className={hint}>
          {hintText}
        </small>
      ) : null}
      {error ? (
        <span id={`${id}-error`} className="text-[10px] leading-[1.6] text-destructive">
          {error}
        </span>
      ) : null}
    </div>
  );
}

interface RadioGroupProps {
  legend: string;
  name: string;
  options: { value: string; label: string }[];
  registration: UseFormRegisterReturn;
  error?: string;
}

function RadioGroup({ legend, name, options, registration, error }: RadioGroupProps) {
  const errorId = `${name}-error`;
  return (
    <fieldset className={cn(field, "sm:col-span-2")} aria-describedby={error ? errorId : undefined}>
      <legend className="mb-2">{legend}</legend>
      <div className="flex flex-wrap gap-x-5 gap-y-2">
        {options.map((option) => (
          <label key={option.value} className="flex items-center gap-2 text-[11px] leading-[1.6]">
            <input type="radio" value={option.value} className="size-[15px] accent-primary" {...registration} />
            {option.label}
          </label>
        ))}
      </div>
      {error ? (
        <span id={errorId} className="text-[10px] leading-[1.6] text-destructive">
          {error}
        </span>
      ) : null}
    </fieldset>
  );
}

interface HostFieldProps {
  id: string;
  registration: UseFormRegisterReturn;
  value: string;
  allowed: string[] | null;
  stored: string | null;
  error?: string;
}

/**
 * SMTP host chosen from the runtime allowlist only (spec §12). A stored host
 * that is no longer allowed stays visible and selected, with a warning, until
 * the operator picks an allowed one.
 */
function HostField({ id, registration, value, allowed, stored, error }: HostFieldProps) {
  const known = [...new Set([stored, value].filter((host): host is string => Boolean(host)))];
  const outside = known.filter((host) => !(allowed && isAllowedHost(allowed, host)));
  const staleStored = stored && allowed !== null && !isAllowedHost(allowed, stored) ? stored : null;
  const hintId = `${id}-hint`;
  const warningId = `${id}-warning`;
  return (
    <div className={field}>
      <label htmlFor={id}>Host SMTP</label>
      <select
        id={id}
        className={input}
        disabled={allowed === null || allowed.length === 0}
        aria-invalid={error ? true : undefined}
        aria-describedby={ids(hintId, staleStored ? warningId : null, error ? `${id}-error` : null)}
        {...registration}
      >
        <option value="">{allowed === null ? "Wczytywanie listy hostów…" : "Wybierz host"}</option>
        {outside.map((host) => (
          <option key={`outside-${host}`} value={host}>
            {host} (spoza listy dozwolonych)
          </option>
        ))}
        {(allowed ?? []).map((host) => (
          <option key={host} value={host}>
            {host}
          </option>
        ))}
      </select>
      <small id={hintId} className={hint}>
        Lista pochodzi z ustawienia intake.smtp_allowed_hosts wdrożenia; z innymi hostami Harmony się nie łączy.
      </small>
      {staleStored ? (
        <span id={warningId} className="flex items-start gap-1.5 text-[10px] leading-[1.6] text-warning">
          <TriangleAlert aria-hidden className="mt-px size-3 shrink-0" strokeWidth={1.8} />
          Zapisany host {staleStored} nie jest na liście dozwolonych (intake.smtp_allowed_hosts). Wybierz host z listy — do tego
          czasu test i wysyłka tym połączeniem się nie powiodą.
        </span>
      ) : null}
      {error ? (
        <span id={`${id}-error`} className="text-[10px] leading-[1.6] text-destructive">
          {error}
        </span>
      ) : null}
    </div>
  );
}

function storedHost(connection: IntegrationConnection | undefined): string | null {
  const host = connection?.kind === "smtp" ? connection.settings?.host : null;
  return typeof host === "string" && host !== "" ? host : null;
}

function secretHint(kind: IntegrationKind, connection: IntegrationConnection | undefined): string {
  const what = kind === "jira_cloud" ? "Token API Atlassian, nie hasło konta. " : "";
  if (!connection) return `${what}Sekret jest tylko do zapisu — po zapisaniu nie będzie wyświetlany.`;
  if (connection.secret_state === "set") {
    return `${what}Sekret jest zapisany i nie jest wyświetlany. Pozostaw pole puste, aby go zachować, albo wpisz nowy, aby go zastąpić.`;
  }
  return `${what}Brak zapisanego sekretu. Bez niego połączenia nie można sprawdzić ani włączyć.`;
}

export interface IntegrationFormProps {
  kind: IntegrationKind;
  connection?: IntegrationConnection;
  onSaved: (connection: IntegrationConnection, created: boolean) => void;
  onCancel: () => void;
}

export function IntegrationForm({ kind, connection, onSaved, onCancel }: IntegrationFormProps) {
  const prefix = useId();
  const [base, setBase] = useState<IntegrationConnection | undefined>(connection);
  const [failure, setFailure] = useState<Failure | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const { smtpAllowedHosts } = useConnections();
  const allowedHosts = kind === "smtp" ? smtpAllowedHosts : null;
  const noAllowedHost = kind === "smtp" && allowedHosts !== null && allowedHosts.length === 0;
  const schema = useMemo(() => integrationFormSchema(kind, allowedHosts), [kind, allowedHosts]);

  const form = useForm<IntegrationFormValues>({
    resolver: yupResolver(schema) as Resolver<IntegrationFormValues>,
    defaultValues: base ? formValuesFromConnection(base) : emptyFormValues(kind),
  });
  const { register, handleSubmit, reset, setError, control, formState } = form;
  const errors = formState.errors;
  const authMode = useWatch({ control, name: "auth_mode" });
  const hostValue = useWatch({ control, name: "host" });

  const create = useCreateIntegration();
  const update = useUpdateIntegration(base?.id ?? "");
  const reload = useReloadIntegration(base?.id ?? "");
  const pending = create.isPending || update.isPending;

  const id = (name: string) => `${prefix}-${name}`;
  const err = (name: FieldName) => errors[name]?.message;

  const applyServerErrors = (error: unknown) => {
    if (error instanceof ApiError && error.status === 409 && error.code === "stale_version") {
      setFailure({ message: integrationErrorMessage(error), stale: true, details: [] });
      return;
    }
    const details: string[] = [];
    if (error instanceof ApiError && error.fields) {
      for (const key of Object.keys(error.fields)) {
        const known = SERVER_FIELDS[key];
        if (known) setError(known.field, { type: "server", message: known.message });
        else details.push(FORM_LEVEL[key] ?? `Serwer odrzucił pole „${key}”.`);
      }
    }
    setFailure({ message: integrationErrorMessage(error), stale: false, details });
  };

  const onSubmit = async (values: IntegrationFormValues) => {
    setFailure(null);
    setNotice(null);
    try {
      if (!base) {
        const created = await create.mutateAsync(toConnectionInput(kind, values));
        setBase(created);
        reset(formValuesFromConnection(created));
        onSaved(created, true);
        return;
      }
      const patch = connectionPatch(base, values);
      if (Object.keys(patch).length === 0) {
        setNotice("Brak zmian do zapisania.");
        return;
      }
      const saved = await update.mutateAsync({ version: base.lock_version, ...patch });
      setBase(saved);
      reset(formValuesFromConnection(saved));
      onSaved(saved, false);
    } catch (error) {
      applyServerErrors(error);
    }
  };

  const loadCurrent = () =>
    reload.mutate(undefined, {
      onSuccess: (fresh) => {
        setBase(fresh);
        reset(formValuesFromConnection(fresh));
        setFailure(null);
        setNotice("Wczytano aktualną wersję połączenia.");
      },
    });

  return (
    <form noValidate onSubmit={handleSubmit(onSubmit)} className="grid gap-5">
      <div className="grid gap-4 sm:grid-cols-2">
        <TextField
          id={id("name")}
          label="Nazwa połączenia"
          registration={register("name")}
          error={err("name")}
          maxLength={MAX_NAME_LENGTH}
          className="sm:col-span-2"
        />

        {kind === "jira_cloud" ? (
          <>
            <TextField
              id={id("site_url")}
              label="Adres witryny Jira"
              type="url"
              registration={register("site_url")}
              error={err("site_url")}
              hint="Tylko https://<nazwa>.atlassian.net. Po pierwszym użyciu połączenia adresu nie można zmienić."
              className="sm:col-span-2"
            />
            <RadioGroup
              legend="Sposób uwierzytelniania"
              name={id("auth_mode")}
              registration={register("auth_mode")}
              error={err("auth_mode")}
              options={[
                { value: "classic", label: "Klasyczny token API (e-mail konta + token)" },
                { value: "scoped", label: "Token z zakresami (scoped, Cloud ID)" },
              ]}
            />
            {authMode === "classic" ? (
              <TextField
                id={id("account_email")}
                label="E-mail konta Atlassian"
                type="email"
                registration={register("account_email")}
                error={err("account_email")}
                hint="Konto, do którego należy token API."
                className="sm:col-span-2"
              />
            ) : (
              <TextField
                id={id("cloud_id")}
                label="Cloud ID"
                registration={register("cloud_id")}
                error={err("cloud_id")}
                hint="Identyfikator witryny Atlassian (UUID). Zapytania idą przez stały host api.atlassian.com."
                className="sm:col-span-2"
              />
            )}
          </>
        ) : null}

        {kind === "smtp" ? (
          <>
            <HostField
              id={id("host")}
              registration={register("host")}
              value={hostValue}
              allowed={allowedHosts}
              stored={storedHost(base)}
              error={err("host")}
            />
            <TextField id={id("port")} label="Port" inputMode="numeric" registration={register("port")} error={err("port")} />
            <RadioGroup
              legend="Szyfrowanie"
              name={id("tls_mode")}
              registration={register("tls_mode")}
              error={err("tls_mode")}
              options={[
                { value: "starttls", label: "STARTTLS (zwykle port 587)" },
                { value: "tls", label: "TLS od początku połączenia (zwykle port 465)" },
              ]}
            />
            <TextField id={id("username")} label="Użytkownik" registration={register("username")} error={err("username")} />
            <TextField
              id={id("from_email")}
              label="Adres nadawcy"
              type="email"
              registration={register("from_email")}
              error={err("from_email")}
            />
            <TextField id={id("from_name")} label="Nazwa nadawcy" registration={register("from_name")} error={err("from_name")} />
            <TextField
              id={id("message_id_domain")}
              label="Domena Message-ID"
              registration={register("message_id_domain")}
              error={err("message_id_domain")}
              hint="Domena w nagłówku Message-ID, np. example.com."
            />
          </>
        ) : null}

        {kind === "smsapi" ? (
          <>
            <TextField
              id={id("sender")}
              label="Nazwa nadawcy SMS"
              registration={register("sender")}
              error={err("sender")}
              hint={`Nazwa zatwierdzona w SMSAPI, do ${MAX_SENDER_LENGTH} znaków.`}
            />
            <p className="flex items-start gap-2 self-end rounded-[7px] border bg-background p-3 text-[11px] leading-[1.7] text-muted-foreground">
              <Info aria-hidden className="mt-0.5 size-3.5 shrink-0 text-primary" strokeWidth={1.6} />
              <span>Alert SMS ma limit 134 jednostek UTF-16, czyli maksymalnie dwa płatne segmenty SMS.</span>
            </p>
          </>
        ) : null}

        <TextField
          id={id("secret")}
          label={SECRET_LABEL[kind]}
          type="password"
          autoComplete="new-password"
          registration={register("secret")}
          error={err("secret")}
          hint={secretHint(kind, base)}
          className="sm:col-span-2"
        />
      </div>

      {noAllowedHost ? (
        <p role="alert" className="flex items-start gap-1.5 rounded-[7px] border border-warning/30 bg-warning-surface p-3 text-[11px] leading-[1.6] text-warning">
          <TriangleAlert aria-hidden className="mt-px size-3 shrink-0" strokeWidth={1.8} />
          Brak dozwolonych hostów SMTP: operator wdrożenia musi ustawić intake.smtp_allowed_hosts, zanim zapiszesz połączenie SMTP.
        </p>
      ) : null}
      {failure ? (
        <div role="alert" className="grid justify-items-start gap-1.5 rounded-[7px] border border-destructive/30 bg-destructive-surface p-3 text-[11px] leading-[1.6] text-destructive">
          <p className="flex items-start gap-1.5">
            <TriangleAlert aria-hidden className="mt-px size-3 shrink-0" strokeWidth={1.8} />
            {failure.message}
          </p>
          {failure.details.map((detail) => (
            <p key={detail}>{detail}</p>
          ))}
          {failure.stale ? (
            <Button type="button" variant="outline" size="sm" className="bg-card" disabled={reload.isPending} onClick={loadCurrent}>
              {reload.isPending ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : null}
              Wczytaj aktualną wersję
            </Button>
          ) : null}
          {reload.isError ? <p>{integrationErrorMessage(reload.error)}</p> : null}
        </div>
      ) : null}
      <p role="status" aria-live="polite" className="text-[11px] text-muted-foreground empty:hidden">
        {notice ?? ""}
      </p>

      <div className="flex flex-wrap justify-end gap-2.5">
        <Button type="button" variant="outline" className={cn(actionButton, "bg-card")} onClick={onCancel}>
          Anuluj
        </Button>
        <Button type="submit" className={actionButton} disabled={pending || noAllowedHost}>
          {pending ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : null}
          Zapisz połączenie
        </Button>
      </div>
    </form>
  );
}
