import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { IntegrationForm } from "@/features/integrations/IntegrationForm";
import {
  apiError,
  CLOUD_ID,
  installIntegrationServer,
  makeConnection,
  SMS_ID,
  SMTP_ID,
  SMTP_SETTINGS,
  type IntegrationServer,
} from "@/test/integrationServer";
import type { IntegrationConnection, IntegrationKind } from "@/types/contract";

let server: IntegrationServer;

function renderForm(kind: IntegrationKind, connection?: IntegrationConnection) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
  const onSaved = vi.fn();
  const onCancel = vi.fn();
  const view = render(
    <QueryClientProvider client={queryClient}>
      <IntegrationForm kind={kind} connection={connection} onSaved={onSaved} onCancel={onCancel} />
    </QueryClientProvider>,
  );
  return { onSaved, onCancel, view };
}

function describedBy(element: HTMLElement): string {
  return (element.getAttribute("aria-describedby") ?? "")
    .split(" ")
    .filter(Boolean)
    .map((id) => document.getElementById(id)?.textContent ?? "")
    .join(" ");
}

const save = () => userEvent.click(screen.getByRole("button", { name: "Zapisz połączenie" }));

beforeEach(() => {
  server = installIntegrationServer();
  localStorage.clear();
  sessionStorage.clear();
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("IntegrationForm — write-only secrets (T25.1)", () => {
  it("never shows a stored secret as the input value nor writes a typed one to browser storage", async () => {
    const setItem = vi.spyOn(Storage.prototype, "setItem");
    const { onSaved } = renderForm("jira_cloud", makeConnection());

    const secret = screen.getByLabelText("Token API Jira") as HTMLInputElement;
    expect(secret).toHaveAttribute("type", "password");
    expect(secret).toHaveAttribute("autocomplete", "new-password");
    expect(secret.value).toBe("");
    expect(describedBy(secret)).toMatch(/Sekret jest zapisany i nie jest wyświetlany/);

    await userEvent.type(secret, "tajny-token-123");
    await save();

    await waitFor(() => expect(onSaved).toHaveBeenCalled());
    const [patch] = server.requests("PATCH", `/api/v1/integrations/${makeConnection().id}`);
    expect(patch.body).toEqual({ version: 1, secret: "tajny-token-123" });

    // After the save the field is empty again and the value lives nowhere in the page or storage.
    expect((screen.getByLabelText("Token API Jira") as HTMLInputElement).value).toBe("");
    expect(document.body.innerHTML).not.toContain("tajny-token-123");
    const stored = setItem.mock.calls.map((args) => args.join("="));
    expect(stored.some((entry) => entry.includes("tajny-token-123"))).toBe(false);
    expect(JSON.stringify({ ...localStorage })).not.toContain("tajny-token-123");
    expect(JSON.stringify({ ...sessionStorage })).not.toContain("tajny-token-123");
  });

  it("keeps the stored secret by sending only the changed fields", async () => {
    const { onSaved } = renderForm("jira_cloud", makeConnection());

    const name = screen.getByLabelText("Nazwa połączenia");
    await userEvent.clear(name);
    await userEvent.type(name, "Jira · Wsparcie");
    await save();

    await waitFor(() => expect(onSaved).toHaveBeenCalled());
    const [patch] = server.requests("PATCH", `/api/v1/integrations/${makeConnection().id}`);
    expect(patch.body).toEqual({ version: 1, name: "Jira · Wsparcie" });
  });

  it("does not report a normalized site URL as a change", async () => {
    const stored = makeConnection({ settings: { site_url: "https://electrum.atlassian.net/", auth_mode: "classic", account_email: "ops@electrum.pl" } });
    const { onSaved } = renderForm("jira_cloud", stored);
    await userEvent.type(screen.getByLabelText("Nazwa połączenia"), " 2");
    await save();
    await waitFor(() => expect(onSaved).toHaveBeenCalled());
    const [patch] = server.requests("PATCH", `/api/v1/integrations/${stored.id}`);
    expect(patch.body).toEqual({ version: 1, name: "Jira · Electrum 2" });
  });

  it("says when no secret is stored yet", () => {
    renderForm("jira_cloud", makeConnection({ secret_state: "unset" }));
    expect(describedBy(screen.getByLabelText("Token API Jira"))).toMatch(/Brak zapisanego sekretu/);
  });
});

describe("IntegrationForm — provider settings (T25.2)", () => {
  it("requires the account e-mail for classic Jira and the cloud ID for scoped Jira", async () => {
    const { onSaved } = renderForm("jira_cloud");

    await userEvent.type(screen.getByLabelText("Nazwa połączenia"), "Jira · Electrum");
    await userEvent.type(screen.getByLabelText("Adres witryny Jira"), "http://electrum.example.com");
    await save();

    const site = screen.getByLabelText("Adres witryny Jira");
    expect(site).toHaveAttribute("aria-invalid", "true");
    expect(describedBy(site)).toMatch(/https:\/\/<nazwa>\.atlassian\.net/);
    const email = screen.getByLabelText("E-mail konta Atlassian");
    expect(describedBy(email)).toMatch(/Podaj e-mail konta/);
    expect(screen.queryByLabelText("Cloud ID")).not.toBeInTheDocument();
    expect(server.mutations()).toHaveLength(0);

    await userEvent.click(screen.getByRole("radio", { name: /Token z zakresami/ }));
    expect(screen.queryByLabelText("E-mail konta Atlassian")).not.toBeInTheDocument();
    await userEvent.clear(site);
    await userEvent.type(site, "https://Electrum.atlassian.net/");
    await userEvent.type(screen.getByLabelText("Cloud ID"), "nie-uuid");
    await save();
    expect(describedBy(screen.getByLabelText("Cloud ID"))).toMatch(/Cloud ID ma postać UUID/);
    expect(server.mutations()).toHaveLength(0);

    await userEvent.clear(screen.getByLabelText("Cloud ID"));
    await userEvent.type(screen.getByLabelText("Cloud ID"), CLOUD_ID);
    await userEvent.type(screen.getByLabelText("Token API Jira"), "token-scoped");
    await save();

    await waitFor(() => expect(onSaved).toHaveBeenCalled());
    const [post] = server.requests("POST", "/api/v1/integrations");
    expect(post.body).toEqual({
      kind: "jira_cloud",
      name: "Jira · Electrum",
      settings: { site_url: "https://electrum.atlassian.net", auth_mode: "scoped", cloud_id: CLOUD_ID },
      secret: "token-scoped",
    });
  });

  it("sends classic Jira with the account e-mail and no cloud ID", async () => {
    const { onSaved } = renderForm("jira_cloud");
    await userEvent.type(screen.getByLabelText("Nazwa połączenia"), "Jira");
    await userEvent.type(screen.getByLabelText("Adres witryny Jira"), "https://electrum.atlassian.net");
    await userEvent.type(screen.getByLabelText("E-mail konta Atlassian"), "ops@electrum.pl");
    await save();

    await waitFor(() => expect(onSaved).toHaveBeenCalled());
    const [post] = server.requests("POST", "/api/v1/integrations");
    expect(post.body).toEqual({
      kind: "jira_cloud",
      name: "Jira",
      settings: { site_url: "https://electrum.atlassian.net", auth_mode: "classic", account_email: "ops@electrum.pl" },
    });
  });

  it("offers only STARTTLS or TLS for SMTP, defaults port 587 and shows the allowlist refusal at the host", async () => {
    server.on("POST /api/v1/integrations", () =>
      apiError(422, "validation_failed", { "settings.host": ["must be listed in intake.smtp_allowed_hosts"] }),
    );
    renderForm("smtp");

    const modes = screen.getAllByRole("radio").map((radio) => (radio as HTMLInputElement).value);
    expect(modes).toEqual(["starttls", "tls"]);
    expect(screen.getByRole("radio", { name: /STARTTLS/ })).toBeChecked();
    expect(screen.getByLabelText("Port")).toHaveValue("587");
    expect(screen.getByLabelText("Nazwa nadawcy")).toHaveValue("Harmony");
    expect(describedBy(screen.getByLabelText("Host SMTP"))).toMatch(/intake\.smtp_allowed_hosts/);

    await save();
    for (const label of ["Nazwa połączenia", "Host SMTP", "Użytkownik", "Adres nadawcy", "Domena Message-ID"]) {
      expect(screen.getByLabelText(label)).toHaveAttribute("aria-invalid", "true");
    }
    expect(server.mutations()).toHaveLength(0);

    await userEvent.type(screen.getByLabelText("Nazwa połączenia"), "Poczta");
    await userEvent.type(screen.getByLabelText("Host SMTP"), "smtp.nieznany.pl");
    await userEvent.clear(screen.getByLabelText("Port"));
    await userEvent.type(screen.getByLabelText("Port"), "465");
    await userEvent.click(screen.getByRole("radio", { name: /TLS od początku/ }));
    await userEvent.type(screen.getByLabelText("Użytkownik"), "harmony");
    await userEvent.type(screen.getByLabelText("Adres nadawcy"), "harmony@electrum.pl");
    await userEvent.type(screen.getByLabelText("Domena Message-ID"), "electrum.pl");
    await userEvent.type(screen.getByLabelText("Hasło SMTP"), "haslo");
    await save();

    await waitFor(() =>
      expect(describedBy(screen.getByLabelText("Host SMTP"))).toMatch(/nie ma na liście dozwolonych hostów SMTP/),
    );
    const [post] = server.requests("POST", "/api/v1/integrations");
    expect(post.body).toEqual({
      kind: "smtp",
      name: "Poczta",
      settings: {
        host: "smtp.nieznany.pl",
        port: 465,
        tls_mode: "tls",
        username: "harmony",
        from_email: "harmony@electrum.pl",
        from_name: "Harmony",
        message_id_domain: "electrum.pl",
      },
      secret: "haslo",
    });
  });

  it("limits the SMSAPI sender to 11 characters and names the two paid segments", async () => {
    const { onSaved } = renderForm("smsapi", makeConnection({ id: SMS_ID, kind: "smsapi", name: "SMS", settings: { sender: "Harmony" } }));

    expect(screen.getByText(/134 jednostek UTF-16/)).toBeInTheDocument();
    expect(screen.getByText(/dwa płatne segmenty/)).toBeInTheDocument();

    const sender = screen.getByLabelText("Nazwa nadawcy SMS");
    await userEvent.clear(sender);
    await userEvent.type(sender, "NadawcaZbytDlugi");
    await save();
    expect(describedBy(sender)).toMatch(/do 11 znaków/);
    expect(server.mutations()).toHaveLength(0);

    await userEvent.clear(sender);
    await userEvent.type(sender, "Electrum");
    await save();
    await waitFor(() => expect(onSaved).toHaveBeenCalled());
    const [patch] = server.requests("PATCH", `/api/v1/integrations/${SMS_ID}`);
    expect(patch.body).toEqual({ version: 1, settings: { sender: "Electrum" } });
  });

  it("sends only the changed SMTP setting in a PATCH", async () => {
    const { onSaved } = renderForm("smtp", makeConnection({ id: SMTP_ID, kind: "smtp", name: "Poczta", settings: { ...SMTP_SETTINGS } }));
    expect((screen.getByLabelText("Hasło SMTP") as HTMLInputElement).value).toBe("");

    await userEvent.clear(screen.getByLabelText("Port"));
    await userEvent.type(screen.getByLabelText("Port"), "2525");
    await save();

    await waitFor(() => expect(onSaved).toHaveBeenCalled());
    const [patch] = server.requests("PATCH", `/api/v1/integrations/${SMTP_ID}`);
    expect(patch.body).toEqual({ version: 1, settings: { port: 2525 } });
  });

  it("does not overwrite a connection changed elsewhere and offers the current version", async () => {
    const { onSaved } = renderForm("jira_cloud", makeConnection());
    server.connections.set(makeConnection().id, makeConnection({ name: "Zmieniona", lock_version: 2 }));

    const name = screen.getByLabelText("Nazwa połączenia");
    await userEvent.clear(name);
    await userEvent.type(name, "Moja nazwa");
    await save();

    expect(await screen.findByRole("alert")).toHaveTextContent(/zmieniło się w międzyczasie/);
    expect(onSaved).not.toHaveBeenCalled();
    expect(server.connections.get(makeConnection().id)?.name).toBe("Zmieniona");

    await userEvent.click(screen.getByRole("button", { name: "Wczytaj aktualną wersję" }));
    await waitFor(() => expect(screen.getByLabelText("Nazwa połączenia")).toHaveValue("Zmieniona"));

    await userEvent.clear(screen.getByLabelText("Nazwa połączenia"));
    await userEvent.type(screen.getByLabelText("Nazwa połączenia"), "Moja nazwa");
    await save();
    await waitFor(() => expect(onSaved).toHaveBeenCalled());
    const patches = server.requests("PATCH", `/api/v1/integrations/${makeConnection().id}`);
    expect(patches.at(-1)?.body).toEqual({ version: 2, name: "Moja nazwa" });
  });
});
