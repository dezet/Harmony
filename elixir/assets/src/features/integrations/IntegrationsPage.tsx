import { useEffect, useId, useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { Dialog } from "@base-ui/react/dialog";
import { ArrowRight, LayoutGrid, Loader2, Mail, Plus, Smartphone, TriangleAlert, Workflow, X, type LucideIcon } from "lucide-react";
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
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { useProjects } from "@/features/projects/useProjects";
import { formatRuleTime, useLinearOptions } from "@/features/automations/useAutomations";
import { IntegrationForm } from "@/features/integrations/IntegrationForm";
import { TestDeliveryDialog } from "@/features/integrations/TestDeliveryDialog";
import {
  checkHint,
  connectionStatus,
  integrationErrorMessage,
  KIND_LABEL,
  rulesUsing,
  stoppedEffects,
  useAllRules,
  useConnections,
  useTestIntegration,
  useUpdateIntegration,
  type StatusTone,
} from "@/features/integrations/useIntegrations";
import type { AutomationRule, IntegrationConnection, IntegrationKind, Project } from "@/types/contract";

// Integrations of layout A (spec §4.6, §10–12): the four provider cards of the
// mockup (Jira, Linear, e-mail, SMS). A provider card lists its connections
// with an honest state — „Połączono” only after a passed check — and the
// actions: read-only check, edit, enable, clear the secret (separately
// confirmed) and, for SMTP/SMSAPI, a test-send in its own dialog. Linear has
// no connection of its own: it uses each project's Linear token.

const smallButton = "h-auto min-h-[30px] gap-1.5 rounded-[7px] px-[9px] py-1.5 text-[11px] font-[550] [&_svg:not([class*='size-'])]:size-3.5";

const TONE: Record<StatusTone, string> = {
  success: "bg-success-surface text-success",
  warning: "bg-warning-surface text-warning",
  danger: "bg-destructive-surface text-destructive",
  neutral: "bg-muted text-muted-foreground",
};

function Badge({ tone, children }: { tone: StatusTone; children: ReactNode }) {
  return <span className={cn("inline-flex shrink-0 items-center rounded-[5px] px-[7px] py-1 text-[10px] leading-[1.25] font-[550]", TONE[tone])}>{children}</span>;
}

interface Provider {
  title: string;
  label: string;
  description: string;
  icon: LucideIcon;
}

const PROVIDERS: Record<IntegrationKind | "linear", Provider> = {
  jira_cloud: {
    title: "Jira",
    label: "Źródło zgłoszeń",
    description: "Odczyt tablic i priorytetów, publikacja wyników analizy.",
    icon: LayoutGrid,
  },
  linear: {
    title: "Linear",
    label: "Koordynacja pracy",
    description: "Powiązane zadania i osobne uruchamianie napraw.",
    icon: Workflow,
  },
  smtp: {
    title: "E-mail",
    label: "Powiadomienia zespołu",
    description: "Alerty o wykrytych zgłoszeniach i wynikach analizy.",
    icon: Mail,
  },
  smsapi: {
    title: "SMS",
    label: "Powiadomienia dyżurnego",
    description: "Pilne zgłoszenia przekazywane na skonfigurowany numer.",
    icon: Smartphone,
  },
};

const plural = new Intl.PluralRules("pl-PL");

function rulesText(rules: AutomationRule[]): string {
  const total = rules.length;
  const active = rules.filter((rule) => rule.enabled || rule.activation_status === "activating").length;
  const form = plural.select(total);
  const word = form === "one" ? "reguła" : form === "few" ? "reguły" : "reguł";
  const activeForm = plural.select(active);
  const activeWord = activeForm === "one" ? "aktywna" : activeForm === "few" ? "aktywne" : "aktywnych";
  return `Korzystają z niego ${total} ${word} (${active} ${activeWord}).`;
}

function settingsSummary(connection: IntegrationConnection): string {
  const settings = connection.settings ?? {};
  const value = (key: string) => (typeof settings[key] === "string" || typeof settings[key] === "number" ? String(settings[key]) : "");
  if (connection.kind === "jira_cloud") {
    const mode = value("auth_mode") === "scoped" ? "token z zakresami" : "token klasyczny";
    return [value("site_url"), mode].filter(Boolean).join(" · ");
  }
  if (connection.kind === "smtp") {
    const tls = value("tls_mode") === "tls" ? "TLS" : "STARTTLS";
    return [value("host") && `${value("host")}:${value("port")}`, tls, value("from_email")].filter(Boolean).join(" · ");
  }
  return value("sender") ? `Nadawca: ${value("sender")}` : "";
}

function ProviderCard({ provider, children }: { provider: Provider; children: ReactNode }) {
  const titleId = useId();
  const Icon = provider.icon;
  return (
    <section aria-labelledby={titleId} className="grid content-start gap-4 rounded-[10px] border bg-card p-[23px] max-[600px]:p-[18px]">
      <div>
        <Icon aria-hidden className="mb-5 size-[25px] text-primary" strokeWidth={1.5} />
        <h2 id={titleId} className="text-[17px] font-semibold">
          {provider.title}
        </h2>
        <p className="mt-3 text-xs leading-[1.8] text-muted-foreground">
          <b className="font-semibold text-foreground">{provider.label}</b>
          <br />
          {provider.description}
        </p>
      </div>
      {children}
    </section>
  );
}

interface ConnectionRowProps {
  connection: IntegrationConnection;
  rules: AutomationRule[] | null;
  onEdit: () => void;
  onTestSend: () => void;
}

function ConnectionRow({ connection, rules, onEdit, onTestSend }: ConnectionRowProps) {
  const nameId = useId();
  const blockedId = useId();
  const check = useTestIntegration(connection);
  const update = useUpdateIntegration(connection.id);
  const [clearing, setClearing] = useState(false);

  const status = connectionStatus(connection);
  const summary = settingsSummary(connection);
  const canSend = connection.kind !== "jira_cloud";
  const hasSecret = connection.secret_state === "set";
  const sendBlocked = !connection.enabled ? "Włącz połączenie, aby wysłać test." : !hasSecret ? "Zapisz sekret, aby wysłać test." : null;
  const used = rules ? rulesUsing(rules, connection.id) : null;
  const lastCheck = check.data;

  const toggle = () => {
    update.reset();
    update.mutate({ version: connection.lock_version, enabled: !connection.enabled });
  };

  const clearSecret = () =>
    update.mutate(
      { version: connection.lock_version, clear_secret: true },
      { onSettled: () => setClearing(false) },
    );

  return (
    <li aria-labelledby={nameId} className="grid gap-2.5 border-t pt-4">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p id={nameId} className="text-[13px] font-semibold">
            {connection.name}
          </p>
          {summary ? <p className="mt-0.5 text-[11px] leading-[1.6] break-words text-muted-foreground">{summary}</p> : null}
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <button
            type="button"
            role="switch"
            aria-checked={connection.enabled}
            aria-label={`Połączenie ${connection.name} włączone`}
            aria-describedby={!connection.enabled && !hasSecret ? blockedId : undefined}
            disabled={update.isPending || (!connection.enabled && !hasSecret)}
            onClick={toggle}
            className={cn(
              "inline-flex h-5 w-[34px] items-center rounded-full p-[3px] outline-none focus-visible:ring-2 focus-visible:ring-ring/50 disabled:cursor-not-allowed disabled:opacity-60",
              connection.enabled ? "bg-primary" : "bg-muted-foreground",
            )}
          >
            <span
              aria-hidden
              className={cn(
                "block size-3.5 rounded-full bg-card transition-transform motion-reduce:transition-none",
                connection.enabled ? "translate-x-3.5" : null,
              )}
            />
          </button>
          <Badge tone={status.tone}>{status.label}</Badge>
        </div>
      </div>

      {status.hint ? (
        <p className={cn("text-[11px] leading-[1.6]", status.tone === "danger" ? "text-destructive" : "text-muted-foreground")}>
          {status.hint}
        </p>
      ) : null}
      {!connection.enabled ? (
        <p className="flex items-start gap-1.5 rounded-[7px] border border-warning/30 bg-warning-surface p-2.5 text-[11px] leading-[1.6] text-warning">
          <TriangleAlert aria-hidden className="mt-px size-3 shrink-0" strokeWidth={1.8} />
          <span>
            {stoppedEffects(connection.kind)}
            {!hasSecret ? <span id={blockedId}> Włączenie wymaga zapisanego sekretu.</span> : null}
          </span>
        </p>
      ) : null}

      <div className="flex flex-wrap gap-x-5 gap-y-1 text-[11px] text-muted-foreground">
        <p>Sekret: {hasSecret ? "zapisany" : "brak"}</p>
        <p>Ostatnie sprawdzenie: {formatRuleTime(connection.last_checked_at)}</p>
        {used && used.length > 0 ? <p>{rulesText(used)}</p> : null}
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <Button
          type="button"
          variant="outline"
          size="sm"
          className={cn(smallButton, "bg-card")}
          disabled={check.isPending}
          onClick={() => check.mutate()}
        >
          {check.isPending ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : <ArrowRight aria-hidden />}
          Sprawdź połączenie
        </Button>
        <Button type="button" variant="outline" size="sm" className={cn(smallButton, "bg-card")} onClick={onEdit}>
          Edytuj
        </Button>
        {canSend ? (
          <Button
            type="button"
            variant="outline"
            size="sm"
            className={cn(smallButton, "bg-card")}
            disabled={sendBlocked !== null}
            title={sendBlocked ?? undefined}
            onClick={onTestSend}
          >
            Wyślij test
          </Button>
        ) : null}
        {hasSecret ? (
          <Button type="button" variant="destructive" size="sm" className={smallButton} onClick={() => setClearing(true)}>
            Usuń sekret
          </Button>
        ) : null}
      </div>

      <p role="status" aria-live="polite" className="text-[11px] leading-[1.6] empty:hidden">
        {check.isError ? (
          <span className="text-destructive">{integrationErrorMessage(check.error)}</span>
        ) : lastCheck ? (
          lastCheck.health === "ok" ? (
            <span className="text-success">Połączenie działa. Test nie wysłał żadnej wiadomości.</span>
          ) : (
            <span className="text-destructive">
              {checkHint(lastCheck.error_code)} Test nie wysłał żadnej wiadomości.
            </span>
          )
        ) : null}
      </p>
      {update.isError ? (
        <p role="alert" className="text-[11px] leading-[1.5] text-destructive">
          {integrationErrorMessage(update.error)}
        </p>
      ) : null}

      <AlertDialog open={clearing} onOpenChange={setClearing}>
        <AlertDialogContent className="data-[size=default]:max-w-[calc(100%-2rem)] data-[size=default]:sm:max-w-md">
          <AlertDialogHeader>
            <AlertDialogTitle>Usunąć zapisany sekret?</AlertDialogTitle>
            <AlertDialogDescription render={<div />} className="grid gap-2 text-left text-xs leading-[1.6]">
              <p>
                Sekret połączenia „{connection.name}” zostanie trwale usunięty, a połączenie zostanie wyłączone. Wszystkie
                aktywne reguły, które z niego korzystają, zostaną wstrzymane.
              </p>
              {used && used.length > 0 ? <p>{rulesText(used)}</p> : null}
              <p>Aby wznowić pracę, zapisz nowy sekret, włącz połączenie i ponownie aktywuj reguły.</p>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Anuluj</AlertDialogCancel>
            <Button variant="destructive" disabled={update.isPending} onClick={clearSecret}>
              {update.isPending ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : null}
              Usuń sekret i wyłącz
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </li>
  );
}

function LinearProjectRow({ project }: { project: Project }) {
  const nameId = useId();
  const [checking, setChecking] = useState(false);
  const options = useLinearOptions(checking ? project.id : "");
  const name = project.display_name || project.slug;
  const target = [project.linear_team_key && `Zespół ${project.linear_team_key}`, project.linear_project_slug && `projekt ${project.linear_project_slug}`]
    .filter(Boolean)
    .join(" · ");

  return (
    <li aria-labelledby={nameId} className="grid gap-2 border-t pt-4">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p id={nameId} className="text-[13px] font-semibold">
            {name}
          </p>
          {target ? <p className="mt-0.5 text-[11px] text-muted-foreground">{target}</p> : null}
        </div>
        <Badge tone={project.tracker_secret === "set" ? "neutral" : "warning"}>
          {project.tracker_secret === "set" ? "Token projektu" : "Bez tokenu projektu"}
        </Badge>
      </div>
      <p className="text-[11px] leading-[1.6] text-muted-foreground">
        {project.tracker_secret === "set"
          ? "Token Linear zapisany w projekcie."
          : "Projekt nie ma własnego tokenu Linear — Harmony użyje tokenu globalnego z konfiguracji, jeśli jest ustawiony."}
      </p>
      <div className="flex flex-wrap items-center gap-3">
        <Button
          type="button"
          variant="outline"
          size="sm"
          className={cn(smallButton, "bg-card")}
          disabled={options.isFetching}
          onClick={() => (checking ? void options.refetch() : setChecking(true))}
        >
          {options.isFetching ? <Loader2 aria-hidden className="animate-spin motion-reduce:animate-none" /> : <ArrowRight aria-hidden />}
          Sprawdź dostęp
        </Button>
        <Link to={`/projects/${project.id}/edit`} className="text-[11px] text-primary underline underline-offset-4">
          Ustawienia projektu
        </Link>
      </div>
      {options.isError ? (
        <p role="alert" className="text-[11px] leading-[1.6] text-destructive">
          {integrationErrorMessage(options.error)}
        </p>
      ) : options.isSuccess ? (
        <p role="status" className="text-[11px] leading-[1.6] text-success">
          Dostęp do Linear działa: widoczne zespoły — {options.data.teams.length}. Sprawdzenie niczego nie zmieniło w Linear.
        </p>
      ) : null}
    </li>
  );
}

function LinearCard() {
  const projects = useProjects();
  return (
    <ProviderCard provider={PROVIDERS.linear}>
      <p className="rounded-[7px] border bg-background p-3 text-[11px] leading-[1.7] text-muted-foreground">
        Linear nie ma osobnego połączenia: Harmony używa tokenu Linear zapisanego w ustawieniach każdego projektu.
      </p>
      {projects.isPending ? (
        <Skeleton aria-label="Wczytywanie projektów" className="h-[70px] w-full rounded-[7px]" />
      ) : projects.isError ? (
        <div role="alert" className="grid justify-items-start gap-2 text-[11px] text-destructive">
          <p>Nie udało się wczytać projektów.</p>
          <Button type="button" variant="outline" size="sm" className={cn(smallButton, "bg-card")} onClick={() => void projects.refetch()}>
            Spróbuj ponownie
          </Button>
        </div>
      ) : projects.data.length === 0 ? (
        <p className="text-[11px] text-muted-foreground">
          Brak projektów. <Link to="/projects/new" className="text-primary underline underline-offset-4">Dodaj projekt</Link>, aby
          powiązać go z Linear.
        </p>
      ) : (
        <ul className="grid gap-4">
          {projects.data.map((project) => (
            <LinearProjectRow key={project.id} project={project} />
          ))}
        </ul>
      )}
    </ProviderCard>
  );
}

interface ConnectionCardProps {
  kind: IntegrationKind;
  list: ReturnType<typeof useConnections>;
  rules: AutomationRule[] | null;
  onAdd: () => void;
  onEdit: (connection: IntegrationConnection) => void;
  onTestSend: (connection: IntegrationConnection) => void;
}

function ConnectionCard({ kind, list, rules, onAdd, onEdit, onTestSend }: ConnectionCardProps) {
  const connections = list.connections.filter((connection) => connection.kind === kind);
  return (
    <ProviderCard provider={PROVIDERS[kind]}>
      {list.isError && list.connections.length === 0 ? (
        <div role="alert" className="grid justify-items-start gap-2 text-[11px] text-destructive">
          <p className="font-[550]">Nie udało się wczytać połączeń.</p>
          <p>{integrationErrorMessage(list.error)}</p>
          <Button type="button" variant="outline" size="sm" className={cn(smallButton, "bg-card")} onClick={() => void list.refetch()}>
            Spróbuj ponownie
          </Button>
        </div>
      ) : list.isPending ? (
        <Skeleton aria-label="Wczytywanie połączeń" className="h-[70px] w-full rounded-[7px]" />
      ) : connections.length === 0 ? (
        <div className="flex items-center justify-between gap-3">
          <Badge tone="neutral">Nie skonfigurowano</Badge>
        </div>
      ) : (
        <ul className="grid gap-4">
          {connections.map((connection) => (
            <ConnectionRow
              key={connection.id}
              connection={connection}
              rules={rules}
              onEdit={() => onEdit(connection)}
              onTestSend={() => onTestSend(connection)}
            />
          ))}
        </ul>
      )}
      {list.isError && list.connections.length === 0 ? null : (
        <Button type="button" variant="outline" size="sm" className={cn(smallButton, "justify-self-start bg-card")} onClick={onAdd}>
          <Plus aria-hidden />
          Dodaj połączenie
        </Button>
      )}
    </ProviderCard>
  );
}

type Editing = { kind: IntegrationKind; connectionId: string | null };

function FormDialog({
  editing,
  connection,
  onClose,
  onCreated,
}: {
  editing: Editing | null;
  connection: IntegrationConnection | undefined;
  onClose: () => void;
  onCreated: () => void;
}) {
  const title = editing
    ? editing.connectionId
      ? `Edycja połączenia · ${connection?.name ?? KIND_LABEL[editing.kind]}`
      : `Nowe połączenie · ${KIND_LABEL[editing.kind]}`
    : "";
  return (
    <Dialog.Root open={editing !== null} onOpenChange={(open) => (open ? undefined : onClose())}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-40 bg-[#11131e88] backdrop-blur-[3px] transition-opacity duration-200 data-ending-style:opacity-0 data-starting-style:opacity-0 motion-reduce:transition-none" />
        <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 flex max-h-[90vh] w-[min(730px,calc(100vw-30px))] -translate-x-1/2 -translate-y-1/2 flex-col overflow-hidden rounded-[13px] border bg-card text-foreground shadow-[0_25px_100px_#0005] outline-none transition-opacity duration-200 data-ending-style:opacity-0 data-starting-style:opacity-0 motion-reduce:transition-none">
          <div className="flex shrink-0 items-center justify-between gap-3 border-b px-5 py-3">
            <Dialog.Title className="text-[14px] font-semibold">{title}</Dialog.Title>
            <Dialog.Close
              aria-label="Zamknij formularz"
              className="inline-flex rounded-[5px] p-[7px] text-foreground outline-none hover:bg-muted focus-visible:ring-2 focus-visible:ring-ring/50"
            >
              <X aria-hidden className="size-4" strokeWidth={1.6} />
            </Dialog.Close>
          </div>
          <div className="overflow-y-auto p-5">
            {editing && (editing.connectionId === null || connection) ? (
              <IntegrationForm
                kind={editing.kind}
                connection={connection}
                onCancel={onClose}
                onSaved={(_saved, created) => {
                  if (created) onCreated();
                  onClose();
                }}
              />
            ) : null}
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

export function IntegrationsPage() {
  const list = useConnections();
  const allRules = useAllRules();
  const [editing, setEditing] = useState<Editing | null>(null);
  const [testing, setTesting] = useState<IntegrationConnection | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    document.title = "Integracje — Harmony";
  }, []);

  const rules = allRules.ready ? allRules.rules : null;
  const editedConnection = editing?.connectionId
    ? list.connections.find((connection) => connection.id === editing.connectionId)
    : undefined;

  const card = (kind: IntegrationKind) => (
    <ConnectionCard
      kind={kind}
      list={list}
      rules={rules}
      onAdd={() => {
        setNotice(null);
        setEditing({ kind, connectionId: null });
      }}
      onEdit={(connection) => {
        setNotice(null);
        setEditing({ kind, connectionId: connection.id });
      }}
      onTestSend={setTesting}
    />
  );

  return (
    <div>
      <div className="mb-[23px] min-w-0">
        <h1 className="text-title max-[1150px]:text-[26px] max-[600px]:text-[27px]">Integracje</h1>
        <p className="mt-2 text-xs leading-[1.6] text-muted-foreground">Połączenia, na których opiera się Twoja automatyzacja.</p>
      </div>

      <p role="status" aria-live="polite" className="mb-4 text-[11px] leading-[1.6] text-success empty:hidden">
        {notice ?? ""}
      </p>

      <div className="grid grid-cols-2 gap-[18px] max-[600px]:grid-cols-1">
        {card("jira_cloud")}
        <LinearCard />
        {card("smtp")}
        {card("smsapi")}
      </div>

      <FormDialog
        editing={editing}
        connection={editedConnection}
        onClose={() => setEditing(null)}
        onCreated={() =>
          setNotice("Połączenie zapisane i wyłączone. Sprawdź je, a potem włącz przełącznikiem przy połączeniu.")
        }
      />
      <TestDeliveryDialog connection={testing} onClose={() => setTesting(null)} />
    </div>
  );
}
