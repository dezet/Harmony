import { vi } from "vitest";
import type { AutomationRule, IntegrationConnection, LinearOptions, Project } from "@/types/contract";
import { LINEAR_OPTIONS, makeRule, PROJECTS } from "@/test/automationServer";

// In-memory intake API for the integration screens. Every request is recorded
// with its headers, so a test can read the Idempotency-Key of a test-send. The
// connection store is mutable and behaves like the backend: PATCH checks the
// `version`, a connection test never bumps it, the stored secret is only ever
// reported as `secret_state`.

export const JIRA_ID = "22222222-2222-4222-8222-222222222222";
export const SMTP_ID = "88888888-8888-4888-8888-888888888888";
export const SMS_ID = "99999999-9999-4999-8999-999999999999";
export const NEW_CONNECTION_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
export const CLOUD_ID = "0e4f7b0c-3a51-4d5c-9c2a-6f1e2d3c4b5a";

export function makeConnection(patch: Partial<IntegrationConnection> = {}): IntegrationConnection {
  return {
    id: JIRA_ID,
    kind: "jira_cloud",
    name: "Jira · Electrum",
    settings: { site_url: "https://electrum.atlassian.net", auth_mode: "classic", account_email: "ops@electrum.pl" },
    secret_state: "set",
    secret_version: 1,
    enabled: true,
    last_checked_at: "2026-09-24T10:00:00Z",
    health: "ok",
    error_code: null,
    lock_version: 1,
    ...patch,
  };
}

export const SMTP_SETTINGS = {
  host: "smtp.electrum.pl",
  port: 587,
  tls_mode: "starttls",
  username: "harmony",
  from_email: "harmony@electrum.pl",
  from_name: "Harmony",
  message_id_domain: "electrum.pl",
};

export function defaultConnections(): IntegrationConnection[] {
  return [
    makeConnection(),
    makeConnection({ id: SMTP_ID, kind: "smtp", name: "Poczta dyżurna", settings: { ...SMTP_SETTINGS } }),
    makeConnection({ id: SMS_ID, kind: "smsapi", name: "SMSAPI dyżur", settings: { sender: "Harmony" } }),
  ];
}

export interface Call {
  method: string;
  path: string;
  search: URLSearchParams;
  headers: Headers;
  body: unknown;
}

type Reply = Response | Promise<Response>;
type Handler = (call: Call) => Reply;

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

export function apiError(status: number, code: string, fields: Record<string, string[]> = {}): Response {
  return json({ error: { code, message: code, fields } }, status);
}

export interface IntegrationServer {
  connections: Map<string, IntegrationConnection>;
  calls: Call[];
  on: (route: string, handler: Handler) => void;
  mutations: () => Call[];
  requests: (method: string, path: string) => Call[];
}

const API = "/api/v1";

interface ServerOptions {
  connections?: IntegrationConnection[];
  rules?: AutomationRule[];
  projects?: Project[];
  linearOptions?: LinearOptions;
  smtpAllowedHosts?: string[];
}

export function installIntegrationServer(options: ServerOptions = {}): IntegrationServer {
  const connections = new Map((options.connections ?? defaultConnections()).map((entry) => [entry.id, entry]));
  const rules = options.rules ?? [makeRule()];
  const projects = options.projects ?? PROJECTS;
  const smtpAllowedHosts = options.smtpAllowedHosts ?? ["smtp.electrum.pl", "smtp2.electrum.pl"];
  const calls: Call[] = [];
  const overrides = new Map<string, Handler>();

  const defaults = (call: Call): Reply => {
    const { method, path } = call;
    const body = (call.body ?? {}) as Record<string, unknown>;

    if (method === "GET" && path === `${API}/csrf`) return json({ csrf_token: "csrf-test" });
    if (method === "GET" && path === `${API}/projects`) return json({ projects });
    if (method === "GET" && path === `${API}/automations`) {
      return json({ items: rules, meta: { next_cursor: null, page_size: 100 } });
    }
    const linear = path.match(/^\/api\/v1\/projects\/([^/]+)\/linear-options$/);
    if (method === "GET" && linear) return json(options.linearOptions ?? LINEAR_OPTIONS);

    if (method === "GET" && path === `${API}/integrations`) {
      return json({
        items: [...connections.values()],
        meta: { next_cursor: null, page_size: 100, smtp_allowed_hosts: smtpAllowedHosts },
      });
    }
    if (method === "POST" && path === `${API}/integrations`) {
      const { secret, ...attrs } = body as { secret?: string } & Partial<IntegrationConnection>;
      const created = makeConnection({
        ...attrs,
        id: NEW_CONNECTION_ID,
        enabled: false,
        health: "unchecked",
        last_checked_at: null,
        secret_state: secret ? "set" : "unset",
      });
      connections.set(created.id, created);
      return json({ connection: created }, 201);
    }

    const match = path.match(/^\/api\/v1\/integrations\/([^/]+)(?:\/([\w-]+))?$/);
    const current = match ? connections.get(match[1]) : undefined;
    if (match && !current) return apiError(404, "not_found");
    if (match && current) {
      const action = match[2];
      if (method === "GET" && !action) return json({ connection: current });
      if (method === "PATCH" && !action) {
        const { version, secret, clear_secret, settings, ...attrs } = body as {
          version?: number;
          secret?: string;
          clear_secret?: boolean;
          settings?: Record<string, unknown>;
        } & Partial<IntegrationConnection>;
        if (version !== current.lock_version) return apiError(409, "stale_version");
        const nextSettings = { ...current.settings, ...(settings ?? {}) };
        const enabled = clear_secret ? false : (attrs.enabled ?? current.enabled);
        // Like Connections.update_input: a change of settings or secret makes the check stale.
        const stale =
          JSON.stringify(nextSettings) !== JSON.stringify(current.settings) ||
          Boolean(secret) ||
          (Boolean(clear_secret) && current.secret_state === "set");
        const next: IntegrationConnection = {
          ...current,
          ...attrs,
          settings: nextSettings,
          secret_state: clear_secret ? "unset" : secret ? "set" : current.secret_state,
          enabled,
          ...(stale ? { health: "unchecked" as const, error_code: null } : {}),
          lock_version: current.lock_version + 1,
        };
        connections.set(next.id, next);
        return json({ connection: next });
      }
      if (method === "POST" && action === "test") {
        // A connection test stores the health without bumping `lock_version`.
        const next = { ...current, health: "ok" as const, error_code: null, last_checked_at: "2026-09-24T12:30:00Z" };
        connections.set(next.id, next);
        return json({ health: next.health, checked_at: next.last_checked_at, error_code: null });
      }
      if (method === "POST" && action === "test-send") {
        return json(
          {
            test_delivery: {
              id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
              operation: current.kind === "smtp" ? "email" : "sms",
              status: "pending",
              attempts: 0,
              next_attempt_at: "2026-09-24T12:30:00Z",
              provider_id: null,
              first_attempt_at: null,
              sent_at: null,
              last_error_code: null,
              retry_allowed: false,
              duplicate_risk: false,
            },
          },
          202,
        );
      }
    }
    return apiError(404, "not_found");
  };

  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input), "http://localhost");
      const method = (init?.method ?? "GET").toUpperCase();
      const body = typeof init?.body === "string" && init.body ? JSON.parse(init.body) : undefined;
      const call: Call = { method, path: url.pathname, search: url.searchParams, headers: new Headers(init?.headers), body };
      calls.push(call);
      const handler = overrides.get(`${method} ${url.pathname}`) ?? defaults;
      return handler(call);
    }),
  );

  return {
    connections,
    calls,
    on: (route, handler) => overrides.set(route, handler),
    mutations: () => calls.filter((call) => call.method !== "GET"),
    requests: (method, path) => calls.filter((call) => call.method === method && call.path === path),
  };
}
